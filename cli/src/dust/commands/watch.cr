require "json"

module Dust
  module Commands
    module Watch
      # dust watch <store> <pattern> [--op <type>]
      def self.watch(config : Config, args : Array(String))
        # Handle --help before auth check
        if args.includes?("--help") || args.includes?("-h")
          puts "Usage: dust watch <store> <pattern> [--op <type>]"
          puts ""
          puts "Stream store changes matching <pattern> as JSON lines to stdout."
          puts "Runs until interrupted (Ctrl+C)."
          puts ""
          puts "Options:"
          puts "  --op <type>    Filter by operation type (set, delete, merge, increment, add, remove)"
          return
        end

        Output.require_auth!(config)

        # Parse args: positional + optional --op flag
        store_name : String? = nil
        pattern : String? = nil
        op_filter : String? = nil
        positional = [] of String

        i = 0
        while i < args.size
          case args[i]
          when "--op"
            if i + 1 < args.size
              op_filter = args[i + 1]
              i += 2
            else
              Output.error("--op requires a value. Usage: dust watch <store> <pattern> [--op <type>]")
              i += 1
            end
          else
            positional << args[i]
            i += 1
          end
        end

        Output.require_args!(positional, 2, "dust watch <store> <pattern> [--op <type>]")
        store_name = positional[0]
        pattern = positional[1]

        conn = Connection.new(config)
        cache = Cache.new
        last_seq = cache.last_seq(store_name.not_nil!)

        # Track whether we've completed initial catch-up
        caught_up = false

        conn.on_event do |topic, payload|
          op = payload["op"]?.try(&.as_s)
          path = payload["path"]?.try(&.as_s)

          next unless op && path

          # Apply glob filter
          next unless Glob.match?(pattern.not_nil!, path)

          # Apply op filter
          if f = op_filter
            next unless op == f
          end

          # Print as one JSON line to stdout
          STDOUT.puts payload.to_json
          STDOUT.flush
        end

        begin
          conn.connect_sync
          channel = conn.join(store_name.not_nil!, last_seq)

          STDERR.puts "Watching #{store_name} for '#{pattern}'... (Ctrl+C to stop)"
          STDERR.flush

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
