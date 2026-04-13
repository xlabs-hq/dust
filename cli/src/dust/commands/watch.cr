require "json"

module Dust
  module Commands
    module Watch
      # dust watch <store> <pattern> [--op <type>] [--include-current] [--limit N] [--order asc|desc]
      def self.watch(config : Config, args : Array(String))
        # Handle --help before auth check
        if args.includes?("--help") || args.includes?("-h")
          puts "Usage: dust watch <store> <pattern> [--op <type>] [--include-current] [--limit N] [--order asc|desc]"
          puts ""
          puts "Stream store changes matching <pattern> as JSON lines to stdout."
          puts "Runs until interrupted (Ctrl+C)."
          puts ""
          puts "Options:"
          puts "  --op <type>        Filter by operation type (set, delete, merge, increment, add, remove)"
          puts "  --include-current  Emit current matching entries as {\"op\":\"present\",...} events before live events"
          puts "  --limit N          Bootstrap page size when --include-current is set (default 50)"
          puts "  --order asc|desc   Bootstrap order when --include-current is set (default asc)"
          return
        end

        Output.require_auth!(config)

        # Parse args: positional + optional flags
        store_name : String? = nil
        pattern : String? = nil
        op_filter : String? = nil
        include_current = false
        bootstrap_limit = 50
        bootstrap_order = "asc"
        positional = [] of String

        i = 0
        while i < args.size
          case args[i]
          when "--op"
            if i + 1 < args.size
              op_filter = args[i + 1]
              i += 2
            else
              Output.error("--op requires a value. Usage: dust watch <store> <pattern> [--op <type>] [--include-current] [--limit N] [--order asc|desc]")
              i += 1
            end
          when "--include-current"
            include_current = true
            i += 1
          when "--limit"
            if i + 1 < args.size
              bootstrap_limit = args[i + 1].to_i
              i += 2
            else
              Output.error("--limit requires a value")
              i += 1
            end
          when "--order"
            if i + 1 < args.size
              bootstrap_order = args[i + 1]
              i += 2
            else
              Output.error("--order requires a value")
              i += 1
            end
          else
            positional << args[i]
            i += 1
          end
        end

        Output.require_args!(positional, 2, "dust watch <store> <pattern> [--op <type>] [--include-current] [--limit N] [--order asc|desc]")
        store_name = positional[0]
        pattern = positional[1]

        conn = Connection.new(config)
        cache = Cache.new
        last_seq = cache.last_seq(store_name.not_nil!)

        # Race-window guard:
        # `phoenix_client` does not buffer server-push events when no binding is
        # registered — unmatched events are silently dropped in Phoenix::Channel#trigger
        # (see cli/lib/phoenix_client/src/phoenix/channel.cr:136-140). The binding
        # itself is attached inside `conn.join`, and it forwards to `@event_handler`
        # which is nil until `conn.on_event` runs. On top of that, WebSocket frames
        # are delivered on a separate fiber from the one running this command, so a
        # broadcast could land between the `join` reply and the end of the bootstrap
        # emit loop.
        #
        # To keep the ordering guarantee ("every matching event — bootstrapped or
        # live — is emitted exactly once, in a consistent shape, with bootstrap
        # before live"), we:
        #   1. Register `conn.on_event` FIRST, with a buffer gated by
        #      `bootstrap_done`. The mutex only protects the `pending` array's
        #      internal consistency against concurrent append (from the WS
        #      fiber) and drain (from this fiber).
        #   2. Join the channel.
        #   3. Read + emit bootstrap entries. Ordering against live events is
        #      gated by `bootstrap_done` — while it is false, the on_event
        #      handler appends to `pending` instead of emitting.
        #   4. Drain any events that arrived into the buffer while bootstrapping.
        #   5. Flip the flag so subsequent events print directly.
        bootstrap_mutex = Mutex.new
        bootstrap_done = false
        pending = [] of JSON::Any

        pattern_str = pattern.not_nil!
        emit_live = ->(payload : JSON::Any) do
          op = payload["op"]?.try(&.as_s)
          path = payload["path"]?.try(&.as_s)

          if op && path && Glob.match?(pattern_str, path)
            filter_ok = true
            if f = op_filter
              filter_ok = op == f
            end
            if filter_ok
              STDOUT.puts payload.to_json
              STDOUT.flush
            end
          end
        end

        conn.on_event do |_topic, payload|
          flush_now = false

          bootstrap_mutex.synchronize do
            if bootstrap_done
              flush_now = true
            else
              pending << payload
            end
          end

          if flush_now
            emit_live.call(payload)
          end
        end

        begin
          conn.connect_sync
          channel = conn.join(store_name.not_nil!, last_seq)

          STDERR.puts "Watching #{store_name} for '#{pattern}'... (Ctrl+C to stop)"
          STDERR.flush

          # Bootstrap emission: read matching entries from the local cache and
          # print them as {"op":"present", ...} lines BEFORE any live event is
          # allowed through. Ordering against live events is gated by
          # `bootstrap_done` (set below); the mutex only protects the `pending`
          # array against concurrent append/drain between fibers. The emit
          # loop itself is NOT wrapped in synchronize — live events that
          # arrive on the WS fiber during this window append to `pending`
          # under the mutex and are drained after this block.
          if include_current
            items, _ = cache.browse(
              store_name.not_nil!,
              pattern: pattern.not_nil!,
              limit: bootstrap_limit,
              order: bootstrap_order,
              select_as: "entries",
            )

            # `select_as: "entries"` always returns Array(BrowseEntry).
            entries = items.as(Array(Dust::Cache::BrowseEntry))

            entries.each do |row|
              if f = op_filter
                next unless "present" == f
              end
              event = {
                "op"    => JSON::Any.new("present"),
                "path"  => JSON::Any.new(row[:path]),
                "value" => row[:value],
                "type"  => JSON::Any.new(row[:type]),
                "seq"   => JSON::Any.new(row[:seq]),
              }
              STDOUT.puts event.to_json
              STDOUT.flush
            end
          end

          # Drain any live events that arrived while bootstrapping, then flip
          # the flag so future events print directly.
          drained : Array(JSON::Any) = [] of JSON::Any
          bootstrap_mutex.synchronize do
            drained = pending.dup
            pending.clear
            bootstrap_done = true
          end
          drained.each { |payload| emit_live.call(payload) }

          # Block until connection closes or signal
          Signal::INT.trap do
            STDERR.puts "\nStopped."
            conn.close
            cache.close
            exit 0
          end

          Signal::TERM.trap do
            conn.close
            cache.close
            exit 0
          end

          # Keep the main fiber alive while connection runs
          while conn.running?
            sleep 1.second
          end
        ensure
          conn.close
          cache.close
        end
      end
    end
  end
end
