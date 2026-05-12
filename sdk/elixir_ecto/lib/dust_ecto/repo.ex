defmodule DustEcto.Repo do
  @moduledoc """
  Ecto-shaped facade over the active `DustEcto.Transport`. Functions
  mirror the parts of `Ecto.Repo` that map cleanly onto Dust's flat KV
  model: `all/1`, `get/2` + `get!/2`, `stream/1`, `exists?/2`, plus
  `insert/1`, `update/1`, `delete/1` + `delete/2`, and `delete_all/1`.

  No `where`, no `from`, no `preload`, no `insert_all`, no
  `transaction` (yet — pending the upstream `entries.batch_write`
  primitive that's now shipped, plus a corresponding SDK transport
  implementation).

  ## Honest contract

  Dust writes are upserts. There's no atomic insert-or-fail or
  read-modify-write at the wire level (capver 2 has leaf-only CAS).
  `insert/1` and `update/1` are both **validated upserts**: they run
  the changeset, then write. If you need INSERT-or-fail semantics, do
  a `Repo.exists?/2` check first and accept that another writer can
  race you.
  """

  alias DustEcto.{Error, Transport}

  require Logger

  # ------------------------------------------------------------------
  # Reads
  # ------------------------------------------------------------------

  @doc """
  Loads every record of `schema`. Walks every page of the underlying
  enum until `next_cursor` is nil — no silent truncation.

  Records that fail the required-fields guard
  (`schema.__dust_required_fields__/0`) are silently dropped and a
  `Logger.warning` records the slug, missing fields, and any
  unrecognized fields so devs can grep the logs.
  """
  @spec all(module()) :: {:ok, [struct()]} | {:error, Error.t()}
  def all(schema) when is_atom(schema) do
    prefix = schema.__dust_prefix__()
    pattern = "#{prefix}.**"

    case stream_all_items(pattern) do
      {:ok, items} ->
        {:ok, items |> rebuild_records(schema, prefix)}

      err ->
        err
    end
  end

  @doc """
  Returns a `Stream` of records of `schema`, lazy across pages. Useful
  when the prefix could match more than a few hundred records.

  The stream still applies the required-fields guard with the same
  warning behaviour as `all/1`.
  """
  @spec stream(module()) :: Enumerable.t()
  def stream(schema) when is_atom(schema) do
    prefix = schema.__dust_prefix__()
    pattern = "#{prefix}.**"
    {transport, _} = Transport.pick()
    store = Transport.store!()

    # Server enum returns paths in lexicographic order, which means all
    # leaves of a slug land contiguously. We buffer the in-progress
    # slug across page boundaries and emit a record only once we see a
    # leaf belonging to a different slug (or the stream ends).
    Stream.resource(
      fn -> %{cursor: :start, buffer: nil} end,
      fn
        :done ->
          {:halt, :done}

        state ->
          opts = [select: :entries, limit: 100]
          opts = if state.cursor == :start, do: opts, else: Keyword.put(opts, :after, state.cursor)

          case transport.list(store, pattern, opts) do
            {:ok, %{items: items, next_cursor: next}} ->
              {emit, buffer} = group_items_by_slug(items, prefix, state.buffer)
              records = Enum.flat_map(emit, &emit_or_skip(&1, schema))

              cond do
                next == nil and is_nil(buffer) ->
                  {records, :done}

                next == nil ->
                  # Flush the final in-progress slug.
                  {records ++ emit_or_skip(buffer, schema), :done}

                true ->
                  {records, %{cursor: next, buffer: buffer}}
              end

            {:error, reason} ->
              # Raise instead of yielding/filtering — silent truncation
              # is the worst failure mode for a sync consumer that does
              # `Repo.stream(...) |> Enum.to_list()`. Caller can rescue
              # if they want lenient semantics.
              raise "DustEcto.Repo.stream/1 transport error: #{inspect(reason)}"
          end
      end,
      fn _ -> :ok end
    )
  end

  # Walks a list of leaf items, grouping consecutive same-slug entries
  # into `{slug, fields_map}` accumulators. Yields tuples for every
  # slug that *closed* (a leaf for a new slug arrived) and returns the
  # last-still-open slug as the buffer for the next page.
  defp group_items_by_slug(items, prefix, initial_buffer) do
    Enum.reduce(items, {[], initial_buffer}, fn item, {closed, buffer} ->
      case parse_path(item.path, prefix) do
        {:ok, slug, field_segments} ->
          case buffer do
            nil ->
              {closed, {slug, put_nested(%{}, field_segments, item.value)}}

            {^slug, fields} ->
              {closed, {slug, put_nested(fields, field_segments, item.value)}}

            other ->
              {[other | closed], {slug, put_nested(%{}, field_segments, item.value)}}
          end

        :error ->
          {closed, buffer}
      end
    end)
    |> then(fn {closed, buffer} -> {Enum.reverse(closed), buffer} end)
  end

  defp emit_or_skip({slug, fields}, schema) do
    case load_record(schema, slug, fields) do
      {:ok, struct} -> [struct]
      :missing_required -> []
    end
  end

  defp emit_or_skip(nil, _schema), do: []

  @doc """
  Fetches a single record by slug. Returns `{:ok, struct}` on a hit,
  `{:error, :not_found}` on a miss, `{:error, %DustEcto.Error{}}` on
  a transport failure.
  """
  @spec get(module(), String.t()) ::
          {:ok, struct()} | {:error, :not_found | Error.t()}
  def get(schema, slug) when is_atom(schema) and is_binary(slug) do
    prefix = schema.__dust_prefix__()
    {transport, _} = Transport.pick()
    store = Transport.store!()

    case transport.get(store, "#{prefix}.#{slug}") do
      {:ok, %{value: value}} when is_map(value) ->
        case load_record(schema, slug, value) do
          {:ok, struct} -> {:ok, struct}
          :missing_required -> {:error, :not_found}
        end

      {:ok, %{value: scalar}} ->
        # An exact-path leaf with a non-map value lives directly at
        # <prefix>.<slug>. Treat it as a record with no expanded
        # fields — load with empty body and let the required-fields
        # guard speak.
        case load_record(schema, slug, %{}) do
          {:ok, struct} -> {:ok, struct}
          :missing_required ->
            log_skip(schema, slug, %{}, scalar: scalar)
            {:error, :not_found}
        end

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, _} = err ->
        err
    end
  end

  @doc "Like `get/2` but raises if the record is missing or transport errored."
  @spec get!(module(), String.t()) :: struct()
  def get!(schema, slug) do
    case get(schema, slug) do
      {:ok, struct} ->
        struct

      {:error, :not_found} ->
        raise "DustEcto.Repo.get!/2: no #{inspect(schema)} found for slug #{inspect(slug)}"

      {:error, %Error{} = err} ->
        raise "DustEcto.Repo.get!/2: transport error: #{inspect(err)}"
    end
  end

  @doc """
  Cheap existence probe. SDK mode: in-process cache lookup. HTTP mode:
  one HEAD round-trip (no body).
  """
  @spec exists?(module(), String.t()) :: {:ok, boolean()} | {:error, Error.t()}
  def exists?(schema, slug) when is_atom(schema) and is_binary(slug) do
    prefix = schema.__dust_prefix__()
    {transport, _} = Transport.pick()
    store = Transport.store!()

    transport.exists?(store, "#{prefix}.#{slug}")
  end

  # ------------------------------------------------------------------
  # Writes
  # ------------------------------------------------------------------

  @doc """
  Validated upsert. Runs the changeset; on success, dumps the struct
  and writes it to the store.

  Returns `{:ok, struct}`, `{:error, %Ecto.Changeset{}}` on validation
  failure, or `{:error, %DustEcto.Error{}}` on transport failure.
  """
  @spec insert(Ecto.Changeset.t() | struct()) ::
          {:ok, struct()} | {:error, Ecto.Changeset.t() | Error.t()}
  def insert(%Ecto.Changeset{} = cs) do
    case Ecto.Changeset.apply_action(cs, :insert) do
      {:ok, struct} -> write_struct(struct, :all_fields, [])
      {:error, _} = err -> err
    end
  end

  def insert(%_{} = struct), do: write_struct(struct, :all_fields, [])

  @doc "Like `insert/1` but raises on changeset/transport errors."
  @spec insert!(Ecto.Changeset.t() | struct()) :: struct()
  def insert!(input) do
    case insert(input) do
      {:ok, struct} -> struct
      {:error, %Ecto.Changeset{} = cs} -> raise Ecto.InvalidChangesetError, changeset: cs
      {:error, %Error{} = err} -> raise "DustEcto.Repo.insert!/1: #{inspect(err)}"
    end
  end

  @doc """
  Validated upsert. Runs the changeset; on success, dumps the struct
  and writes only the changed fields (in flat mode) or the full
  record (in map mode). Returns the same shapes as `insert/1`.

  ## Options

    * `:if_match` — optimistic-concurrency revision. Only supported on
      `:map`-mode schemas (single leaf write at `<prefix>.<slug>`). In
      `:flat` mode the update is N PUTs, none of which have a meaningful
      whole-record revision — pass `:if_match` and the call raises
      `ArgumentError`. For atomic multi-field CAS use `batch_write/2`.
  """
  @spec update(Ecto.Changeset.t(), keyword()) ::
          {:ok, struct()} | {:error, Ecto.Changeset.t() | Error.t()}
  def update(%Ecto.Changeset{} = cs, opts \\ []) do
    case Ecto.Changeset.apply_action(cs, :update) do
      {:ok, struct} ->
        mode = struct.__struct__.__dust_mode__()

        if Keyword.has_key?(opts, :if_match) and mode == :flat do
          raise ArgumentError,
                ":if_match is only supported on :map-mode schemas. " <>
                  "For atomic multi-field CAS in :flat mode, use Repo.batch_write/2."
        end

        case mode do
          :map ->
            write_struct(struct, :all_fields, opts)

          :flat ->
            changed = cs.changes |> Map.keys() |> Enum.reject(&(&1 == :slug))

            case changed do
              [] -> {:ok, struct}
              fields -> write_struct(struct, fields, opts)
            end
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Removes a record. Accepts a struct or changeset; `delete/2` also
  accepts a `(schema, slug)` shape. Always issues a single `DELETE`
  against `<prefix>.<slug>` — server clears the leaf and every
  descendant.

  ## Options

    * `:if_match` — optimistic-concurrency revision. Server enforces
      leaf-only CAS in capver 2; meaningful for `:map`-mode records
      where the slug path itself is a leaf. On a subtree delete the
      server may ignore or reject — surface as `:conflict`.
  """
  @spec delete(struct() | Ecto.Changeset.t()) ::
          {:ok, %{store_seq: integer()}} | {:error, Error.t()}
  def delete(struct_or_cs), do: delete(struct_or_cs, [])

  @spec delete(struct() | Ecto.Changeset.t() | module(), keyword() | String.t()) ::
          {:ok, %{store_seq: integer()}} | {:error, Error.t()}
  def delete(%Ecto.Changeset{data: struct}, opts) when is_list(opts), do: delete(struct, opts)

  def delete(%schema{slug: slug}, opts) when is_atom(schema) and is_list(opts),
    do: delete(schema, slug, opts)

  def delete(schema, slug) when is_atom(schema) and is_binary(slug),
    do: delete(schema, slug, [])

  @doc """
  Three-arg convenience form accepting `(schema, slug, opts)`. Equivalent
  to `delete(%schema{slug: slug}, opts)`.
  """
  @spec delete(module(), String.t(), keyword()) ::
          {:ok, %{store_seq: integer()}} | {:error, Error.t()}
  def delete(schema, slug, opts) when is_atom(schema) and is_binary(slug) and is_list(opts) do
    prefix = schema.__dust_prefix__()
    {transport, _} = Transport.pick()
    store = Transport.store!()

    transport.delete(store, "#{prefix}.#{slug}", Keyword.take(opts, [:if_match]))
  end

  @doc """
  Atomic multi-record write. Accepts a list of operation tuples:

      Repo.batch_write([
        {:insert, Link.changeset(%Link{}, attrs1)},
        {:insert, Link.changeset(%Link{}, attrs2)},
        {:update, existing_cs, if_match: 7},
        {:delete, Link, "stale-slug"},
        {:delete, Link, "old", if_match: 4}
      ])

  Returns `{:ok, %{store_seq:, ops: [...]}}` on a server-side commit,
  `{:error, %Ecto.Changeset{}}` if any changeset fails validation
  (short-circuits before the batch is sent), or `{:error,
  %DustEcto.Error{}}` on transport failure.

  ## Mode interaction

    * `:map`-mode schemas produce one wire op per record (PUT at
      `<prefix>.<slug>`). `:if_match` applies to that single op.
    * `:flat`-mode schemas produce N wire ops per record (one PUT per
      non-nil field). `:if_match` in `:flat` mode raises
      `ArgumentError` — per-field CAS requires per-field revisions,
      which this v1 API doesn't surface. Open an issue if you need it.

  All ops in a single `batch_write/1` commit atomically server-side —
  either every op lands or none of them does.
  """
  @spec batch_write([tuple()]) ::
          {:ok, %{store_seq: integer(), ops: list()}}
          | {:error, Ecto.Changeset.t() | Error.t()}
  def batch_write(ops) when is_list(ops) do
    case prepare_batch_ops(ops, []) do
      {:ok, transport_ops} ->
        {transport, _} = Transport.pick()
        store = Transport.store!()
        transport.batch_write(store, transport_ops, [])

      {:error, _} = err ->
        err
    end
  end

  defp prepare_batch_ops([], acc), do: {:ok, Enum.reverse(acc)}

  defp prepare_batch_ops([op | rest], acc) do
    case batch_op_to_wire(op) do
      {:ok, wire_ops} -> prepare_batch_ops(rest, Enum.reverse(wire_ops) ++ acc)
      {:error, _} = err -> err
    end
  end

  defp batch_op_to_wire({:insert, %Ecto.Changeset{} = cs}), do: batch_op_to_wire({:insert, cs, []})

  defp batch_op_to_wire({:insert, %Ecto.Changeset{} = cs, opts}) do
    case Ecto.Changeset.apply_action(cs, :insert) do
      {:ok, struct} -> struct_to_wire_ops(struct, :set, opts)
      {:error, cs} -> {:error, cs}
    end
  end

  defp batch_op_to_wire({:update, %Ecto.Changeset{} = cs}), do: batch_op_to_wire({:update, cs, []})

  defp batch_op_to_wire({:update, %Ecto.Changeset{} = cs, opts}) do
    case Ecto.Changeset.apply_action(cs, :update) do
      {:ok, struct} -> struct_to_wire_ops(struct, :set, opts)
      {:error, cs} -> {:error, cs}
    end
  end

  defp batch_op_to_wire({:delete, %_{} = struct}), do: batch_op_to_wire({:delete, struct, []})

  defp batch_op_to_wire({:delete, %schema{slug: slug}, opts}) when is_atom(schema),
    do: batch_op_to_wire({:delete, schema, slug, opts})

  defp batch_op_to_wire({:delete, schema, slug}) when is_atom(schema) and is_binary(slug),
    do: batch_op_to_wire({:delete, schema, slug, []})

  defp batch_op_to_wire({:delete, schema, slug, opts})
       when is_atom(schema) and is_binary(slug) and is_list(opts) do
    prefix = schema.__dust_prefix__()
    op = %{op: :delete, path: "#{prefix}.#{slug}"}

    case Keyword.fetch(opts, :if_match) do
      {:ok, n} when is_integer(n) -> {:ok, [Map.put(op, :if_match, n)]}
      :error -> {:ok, [op]}
    end
  end

  defp batch_op_to_wire(other) do
    {:error,
     Error.new(
       :invalid_params,
       "unrecognised batch_write op: #{inspect(other)}",
       retryable?: false
     )}
  end

  defp struct_to_wire_ops(struct, set_atom, opts) do
    schema = struct.__struct__
    prefix = schema.__dust_prefix__()
    slug = struct.slug
    mode = schema.__dust_mode__()

    cond do
      is_nil(slug) or slug == "" ->
        {:error, Error.new(:invalid_params, "missing slug", retryable?: false)}

      Keyword.has_key?(opts, :if_match) and mode == :flat ->
        raise ArgumentError,
              ":if_match is not supported on :flat-mode schemas in batch_write. " <>
                "Per-field CAS would require per-field revisions; that API isn't exposed yet."

      mode == :map ->
        body = dump_for_wire(struct)
        op = %{op: set_atom, path: "#{prefix}.#{slug}", value: body}

        case Keyword.fetch(opts, :if_match) do
          {:ok, n} when is_integer(n) -> {:ok, [Map.put(op, :if_match, n)]}
          :error -> {:ok, [op]}
        end

      mode == :flat ->
        body = dump_for_wire(struct)

        ops =
          schema.__dust_field_names__()
          |> Enum.reject(&(&1 == :slug))
          |> Enum.flat_map(fn field ->
            case Map.fetch(body, field) do
              {:ok, value} -> [%{op: set_atom, path: "#{prefix}.#{slug}.#{field}", value: value}]
              :error -> []
            end
          end)

        case ops do
          [] ->
            {:error, Error.new(:nothing_to_write, "no fields to write", retryable?: false)}

          ops ->
            {:ok, ops}
        end
    end
  end

  @doc """
  Removes every record of `schema`. Returns `{:ok, %{store_seq: n}}`
  — note the server's DELETE doesn't report a row count.
  """
  @spec delete_all(module()) :: {:ok, %{store_seq: integer()}} | {:error, Error.t()}
  def delete_all(schema) when is_atom(schema) do
    prefix = schema.__dust_prefix__()
    {transport, _} = Transport.pick()
    store = Transport.store!()

    transport.delete(store, prefix, [])
  end

  # ------------------------------------------------------------------
  # Subscribe
  # ------------------------------------------------------------------

  @doc """
  Subscribes the given callback to record-level changes for `schema`.
  Callback receives `{:upserted, struct}` or `{:deleted, slug}` events
  in the dust SDK's `:committed` mode — exactly one delivery per write,
  including for the writer's own changes, with `store_seq` durably
  attached.

  HTTP mode: returns `{:error, %DustEcto.Error{kind: :not_supported}}`.

  The returned ref can be passed to `unsubscribe/1`.
  """
  @spec subscribe(module(), (term() -> any())) ::
          {:ok, reference()} | {:error, Error.t()}
  def subscribe(schema, callback) when is_atom(schema) and is_function(callback, 1) do
    prefix = schema.__dust_prefix__()
    pattern = "#{prefix}.**"
    {transport, _} = Transport.pick()
    store = Transport.store!()

    wrapper = fn event ->
      case ecto_event(schema, prefix, event, transport, store) do
        nil -> :ok
        translated -> callback.(translated)
      end
    end

    transport.subscribe(store, pattern, wrapper)
  end

  @doc """
  Subscribes to the raw underlying op events for `schema` — no
  reassembly into structs. Callback receives the SDK's event map
  `%{op:, path:, value:, store_seq:, ...}` exactly.

  Useful for users who need per-leaf provenance or want to run their
  own assembly. HTTP mode: same `:not_supported` as `subscribe/2`.
  """
  @spec subscribe_raw(module(), (map() -> any())) ::
          {:ok, reference()} | {:error, Error.t()}
  def subscribe_raw(schema, callback) when is_atom(schema) and is_function(callback, 1) do
    prefix = schema.__dust_prefix__()
    pattern = "#{prefix}.**"
    {transport, _} = Transport.pick()
    store = Transport.store!()

    transport.subscribe(store, pattern, callback)
  end

  @doc "Removes a subscription previously registered via subscribe/2 or subscribe_raw/2."
  @spec unsubscribe(reference()) :: :ok
  def unsubscribe(ref) when is_reference(ref) do
    {transport, _} = Transport.pick()
    store = Transport.store!()
    transport.unsubscribe(store, ref)
  end

  defp ecto_event(schema, prefix, %{op: :delete, path: path}, transport, store) do
    case slug_from_path(path, prefix) do
      {:ok, slug, []} ->
        # Whole-record delete: path is exactly `<prefix>.<slug>`.
        {:deleted, slug}

      {:ok, slug, _field_segments} ->
        # Field-level delete: the record may still exist with its
        # remaining fields. Re-read; emit :upserted if it loads, or
        # :deleted only when the slug is truly gone.
        case transport.get(store, "#{prefix}.#{slug}") do
          {:ok, %{value: value}} ->
            case load_record_for_event(schema, slug, value) do
              {:ok, struct} -> {:upserted, struct}
              :error -> {:deleted, slug}
            end

          {:error, :not_found} ->
            {:deleted, slug}

          _ ->
            nil
        end

      :error ->
        nil
    end
  end

  defp ecto_event(schema, prefix, %{path: path} = _event, transport, store) do
    with {:ok, slug, _field_segments} <- slug_from_path(path, prefix),
         {:ok, %{value: value}} <- transport.get(store, "#{prefix}.#{slug}"),
         {:ok, struct} <- load_record_for_event(schema, slug, value) do
      {:upserted, struct}
    else
      _ -> nil
    end
  end

  defp ecto_event(_schema, _prefix, _event, _t, _s), do: nil

  # Walks prefix-many segments off the front of the path; takes the
  # next segment as the slug; the rest is the field-segments tail
  # (empty if the event targets the slug itself, e.g. a whole-record
  # delete). Handles dotted prefixes by splitting both strings and
  # comparing segment-by-segment.
  defp slug_from_path(path, prefix) when is_binary(path) and is_binary(prefix) do
    # Path arrives canonical (slash-rendered) post-segment-first migration.
    # Prefix is whatever the user declared on the schema — may be dotted
    # legacy form or canonical slash. Decode both to segments via the
    # same helpers used everywhere else.
    with {:ok, prefix_segs} <- decode_prefix(prefix),
         {:ok, path_segs} <- Dust.Protocol.Path.parse_rendered(path) do
      prefix_len = length(prefix_segs)

      if Enum.take(path_segs, prefix_len) == prefix_segs do
        case Enum.drop(path_segs, prefix_len) do
          [slug | rest] when slug != "" -> {:ok, slug, rest}
          _ -> :error
        end
      else
        :error
      end
    else
      _ -> :error
    end
  end

  defp load_record_for_event(schema, slug, value) when is_map(value) do
    case load_record(schema, slug, value) do
      {:ok, struct} -> {:ok, struct}
      :missing_required -> :error
    end
  end

  defp load_record_for_event(_schema, _slug, _other), do: :error

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  defp stream_all_items(pattern) do
    {transport, _} = Transport.pick()
    store = Transport.store!()

    do_stream_all(transport, store, pattern, nil, [])
  end

  defp do_stream_all(transport, store, pattern, cursor, acc) do
    opts = [select: :entries, limit: 200]
    opts = if cursor, do: Keyword.put(opts, :after, cursor), else: opts

    case transport.list(store, pattern, opts) do
      {:ok, %{items: items, next_cursor: nil}} ->
        {:ok, acc ++ items}

      {:ok, %{items: items, next_cursor: next}} ->
        do_stream_all(transport, store, pattern, next, acc ++ items)

      {:error, _} = err ->
        err
    end
  end

  # Group items by slug, then rebuild each as a struct. The server's
  # subtree response gives us a fully-assembled value when we GET
  # <prefix>.<slug>; the LIST response, however, returns flat leaf
  # entries. Reassemble by slug.
  #
  # `parse_path/2` handles two cases the original implementation
  # missed: (1) dotted prefixes like `reading.links` (since the prefix
  # itself contains `.`); (2) nested leaf paths like
  # `things.foo.meta.a` produced when a map-typed field gets flattened
  # server-side. The nested leaves get reassembled into a nested map
  # so `Ecto.embedded_load` can reconstruct the original :map field.
  defp rebuild_records(items, schema, prefix) do
    items
    |> Enum.reduce(%{}, fn item, acc ->
      case parse_path(item.path, prefix) do
        {:ok, slug, field_segments} ->
          existing = Map.get(acc, slug, %{})
          Map.put(acc, slug, put_nested(existing, field_segments, item.value))

        :error ->
          acc
      end
    end)
    |> Enum.reduce([], fn {slug, fields}, structs ->
      case load_record(schema, slug, fields) do
        {:ok, struct} -> [struct | structs]
        :missing_required -> structs
      end
    end)
    |> Enum.reverse()
  end

  defp parse_path(path, prefix) when is_binary(path) and is_binary(prefix) do
    with {:ok, prefix_segs} <- decode_prefix(prefix),
         {:ok, path_segs} <- Dust.Protocol.Path.parse_rendered(path) do
      prefix_len = length(prefix_segs)

      if Enum.take(path_segs, prefix_len) == prefix_segs do
        case Enum.drop(path_segs, prefix_len) do
          [slug | [_ | _] = field_segments] when slug != "" ->
            {:ok, slug, field_segments}

          _ ->
            :error
        end
      else
        :error
      end
    else
      _ -> :error
    end
  end

  # Schema prefixes may be declared as either legacy dotted strings
  # (`"reading.links"`) or canonical slash strings (`"reading/links"`).
  # Future work: accept segment-list prefixes per the dust_ecto
  # migration design.
  defp decode_prefix(prefix) when is_binary(prefix) do
    cond do
      String.contains?(prefix, "/") -> Dust.Protocol.Path.parse_rendered(prefix)
      true -> Dust.Protocol.Path.LegacyDot.parse(prefix)
    end
  end

  defp put_nested(map, [key], value), do: Map.put(map, key, value)

  defp put_nested(map, [key | rest], value) do
    child = Map.get(map, key, %{})
    Map.put(map, key, put_nested(child, rest, value))
  end

  # `fields` is a string-keyed map gathered from the LIST response, OR
  # the assembled subtree from a GET response. Inject the slug, run
  # Ecto.embedded_load, then check required fields.
  defp load_record(schema, slug, fields) when is_map(fields) do
    data = Map.put(fields, "slug", slug)
    struct = Ecto.embedded_load(schema, data, :json)

    case missing_required_fields(schema, struct) do
      [] ->
        {:ok, struct}

      missing ->
        log_skip(schema, slug, fields, missing: missing)
        :missing_required
    end
  rescue
    e ->
      Logger.warning(
        "DustEcto.Repo: failed to load #{inspect(schema)} slug=#{inspect(slug)}: " <>
          Exception.message(e)
      )

      :missing_required
  end

  defp missing_required_fields(schema, struct) do
    schema.__dust_required_fields__()
    |> Enum.filter(fn field ->
      case Map.get(struct, field) do
        nil -> true
        "" -> true
        _ -> false
      end
    end)
  end

  defp log_skip(schema, slug, fields, extras) do
    known = schema.__dust_field_names__()
    received = if is_map(fields), do: Map.keys(fields), else: []
    received_atoms = Enum.map(received, &maybe_to_atom/1)
    unrecognized = received_atoms -- known

    Logger.warning(fn ->
      "DustEcto.Repo: skipping #{inspect(schema)} slug=#{inspect(slug)} " <>
        "missing=#{inspect(Keyword.get(extras, :missing, []))} " <>
        "unrecognized=#{inspect(unrecognized)}"
    end)
  end

  defp maybe_to_atom(s) when is_atom(s), do: s

  defp maybe_to_atom(s) when is_binary(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> :__unknown__
  end

  defp write_struct(struct, fields, opts) do
    schema = struct.__struct__
    slug = struct.slug

    cond do
      is_nil(slug) or slug == "" ->
        {:error, Error.new(:invalid_params, "missing slug", retryable?: false)}

      true ->
        case schema.__dust_mode__() do
          :map -> write_map_mode(struct, slug, opts)
          :flat -> write_flat_mode(struct, slug, fields, opts)
        end
    end
  end

  defp write_map_mode(struct, slug, opts) do
    schema = struct.__struct__
    prefix = schema.__dust_prefix__()
    {transport, _} = Transport.pick()
    store = Transport.store!()

    body = dump_for_wire(struct)

    if map_size(body) == 0 do
      {:error, Error.new(:nothing_to_write, "struct dumped to an empty body", retryable?: false)}
    else
      put_opts = Keyword.take(opts, [:if_match])

      case transport.put(store, "#{prefix}.#{slug}", body, put_opts) do
        {:ok, _} -> {:ok, struct}
        err -> err
      end
    end
  end

  defp write_flat_mode(struct, slug, :all_fields, opts) do
    schema = struct.__struct__
    fields = schema.__dust_field_names__() |> Enum.reject(&(&1 == :slug))
    write_flat_mode(struct, slug, fields, opts)
  end

  defp write_flat_mode(struct, slug, fields, _opts) when is_list(fields) do
    # `opts` deliberately unused — flat-mode :if_match is rejected in
    # update/2 before we get here. Any future per-field opt would land
    # in this signature.
    schema = struct.__struct__
    prefix = schema.__dust_prefix__()
    {transport, _} = Transport.pick()
    store = Transport.store!()

    body = dump_for_wire(struct)

    writes =
      Enum.flat_map(fields, fn field ->
        case Map.fetch(body, field) do
          {:ok, value} -> [{field, value}]
          :error -> []
        end
      end)

    case writes do
      [] ->
        {:error, Error.new(:nothing_to_write, "no fields to write", retryable?: false)}

      pairs ->
        Enum.reduce_while(pairs, {:ok, struct}, fn {field, value}, _acc ->
          case transport.put(store, "#{prefix}.#{slug}.#{field}", value, []) do
            {:ok, _} -> {:cont, {:ok, struct}}
            err -> {:halt, err}
          end
        end)
    end
  end

  # Always drop :slug from the wire body — it's the primary key,
  # encoded in the URL path, never serialized as data. Plain-nil fields
  # are kept (write JSON null at that field) since nil is a deliberate
  # value in dust_ecto's contract.
  defp dump_for_wire(struct) do
    struct
    |> Ecto.embedded_dump(:json)
    |> Map.delete(:slug)
    |> Map.delete("slug")
  end
end
