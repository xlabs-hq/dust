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

    Stream.resource(
      fn -> nil end,
      fn cursor ->
        opts = [select: :entries, limit: 100]
        opts = if cursor, do: Keyword.put(opts, :after, cursor), else: opts

        case transport.list(store, pattern, opts) do
          {:ok, %{items: items, next_cursor: next}} ->
            {items, next}

          {:error, _} = err ->
            {[err], :halt}
        end
      end,
      fn _ -> :ok end
    )
    |> Stream.reject(&match?({:error, _}, &1))
    |> Stream.flat_map(fn item ->
      case rebuild_records([item], schema, prefix) do
        [] -> []
        recs -> recs
      end
    end)
  end

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
      {:ok, struct} -> write_struct(struct, :all_fields)
      {:error, _} = err -> err
    end
  end

  def insert(%_{} = struct), do: write_struct(struct, :all_fields)

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
  """
  @spec update(Ecto.Changeset.t()) ::
          {:ok, struct()} | {:error, Ecto.Changeset.t() | Error.t()}
  def update(%Ecto.Changeset{} = cs) do
    case Ecto.Changeset.apply_action(cs, :update) do
      {:ok, struct} ->
        case struct.__struct__.__dust_mode__() do
          :map ->
            write_struct(struct, :all_fields)

          :flat ->
            changed = cs.changes |> Map.keys() |> Enum.reject(&(&1 == :slug))

            case changed do
              [] -> {:ok, struct}
              fields -> write_struct(struct, fields)
            end
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Removes a record. Accepts a struct, a changeset, or a `{schema,
  slug}` tuple. Always issues a single `DELETE` against
  `<prefix>.<slug>` — server clears the leaf and every descendant.
  """
  @spec delete(struct() | Ecto.Changeset.t()) ::
          {:ok, %{store_seq: integer()}} | {:error, Error.t()}
  def delete(%Ecto.Changeset{data: struct}), do: delete(struct)

  def delete(%schema{slug: slug}) when is_atom(schema), do: delete(schema, slug)

  @spec delete(module(), String.t()) ::
          {:ok, %{store_seq: integer()}} | {:error, Error.t()}
  def delete(schema, slug) when is_atom(schema) and is_binary(slug) do
    prefix = schema.__dust_prefix__()
    {transport, _} = Transport.pick()
    store = Transport.store!()

    transport.delete(store, "#{prefix}.#{slug}", [])
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
  defp rebuild_records(items, schema, prefix) do
    items
    |> Enum.reduce(%{}, fn item, acc ->
      case parse_path(item.path, prefix) do
        {:ok, slug, field} ->
          existing = Map.get(acc, slug, %{})
          Map.put(acc, slug, Map.put(existing, field, item.value))

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
    # Expect `<prefix>.<slug>.<field>` (or deeper for nested values, but
    # we only support one level of fields in v1).
    case String.split(path, ".") do
      [^prefix, slug, field] -> {:ok, slug, field}
      _ -> :error
    end
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

  defp write_struct(struct, fields) do
    schema = struct.__struct__
    slug = struct.slug

    cond do
      is_nil(slug) or slug == "" ->
        {:error, Error.new(:invalid_params, "missing slug", retryable?: false)}

      true ->
        case schema.__dust_mode__() do
          :map -> write_map_mode(struct, slug)
          :flat -> write_flat_mode(struct, slug, fields)
        end
    end
  end

  defp write_map_mode(struct, slug) do
    schema = struct.__struct__
    prefix = schema.__dust_prefix__()
    {transport, _} = Transport.pick()
    store = Transport.store!()

    body = dump_for_wire(struct)

    if map_size(body) == 0 do
      {:error, Error.new(:nothing_to_write, "struct dumped to an empty body", retryable?: false)}
    else
      case transport.put(store, "#{prefix}.#{slug}", body, []) do
        {:ok, _} -> {:ok, struct}
        err -> err
      end
    end
  end

  defp write_flat_mode(struct, slug, :all_fields) do
    schema = struct.__struct__
    fields = schema.__dust_field_names__() |> Enum.reject(&(&1 == :slug))
    write_flat_mode(struct, slug, fields)
  end

  defp write_flat_mode(struct, slug, fields) when is_list(fields) do
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
