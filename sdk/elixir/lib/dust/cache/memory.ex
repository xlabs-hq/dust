defmodule Dust.Cache.Memory do
  use GenServer
  @behaviour Dust.Cache

  def start_link(opts) do
    GenServer.start_link(__MODULE__, %{}, opts)
  end

  # Dust.Cache implementation — pid is prepended to all callback args.

  @impl Dust.Cache
  def read(pid, store, path) do
    GenServer.call(pid, {:read, store, path})
  end

  @impl Dust.Cache
  def read_entry(pid, store, path) do
    GenServer.call(pid, {:read_entry, store, path})
  end

  @impl Dust.Cache
  def read_all(pid, store, pattern) do
    GenServer.call(pid, {:read_all, store, pattern})
  end

  @impl Dust.Cache
  def write(pid, store, path, value, type, seq) do
    GenServer.call(pid, {:write, store, path, value, type, seq})
  end

  @impl Dust.Cache
  def write_batch(pid, store, entries) do
    GenServer.call(pid, {:write_batch, store, entries})
  end

  @impl Dust.Cache
  def delete(pid, store, path) do
    GenServer.call(pid, {:delete, store, path})
  end

  @impl Dust.Cache
  def last_seq(pid, store) do
    GenServer.call(pid, {:last_seq, store})
  end

  @impl Dust.Cache
  def count(pid, store) do
    GenServer.call(pid, {:count, store})
  end

  @impl Dust.Cache
  def browse(pid, store, opts) do
    GenServer.call(pid, {:browse, store, opts})
  end

  # Server

  @impl true
  def init(_) do
    {:ok, %{entries: %{}, seqs: %{}}}
  end

  @impl true
  def handle_call({:read, store, path}, _from, state) do
    key = {store, path}
    case Map.get(state.entries, key) do
      nil -> {:reply, :miss, state}
      {value, _type, _seq} -> {:reply, {:ok, value}, state}
    end
  end

  @impl true
  def handle_call({:read_entry, store, path}, _from, state) do
    case Map.get(state.entries, {store, path}) do
      nil -> {:reply, :miss, state}
      {value, type, seq} -> {:reply, {:ok, {value, type, seq}}, state}
    end
  end

  @impl true
  def handle_call({:read_all, store, pattern}, _from, state) do
    compiled = Dust.Protocol.Glob.compile(pattern)

    results =
      state.entries
      |> Enum.filter(fn {{s, path}, _} ->
        s == store and Dust.Protocol.Glob.match?(compiled, String.split(path, "."))
      end)
      |> Enum.map(fn {{_s, path}, {value, _type, _seq}} -> {path, value} end)

    {:reply, results, state}
  end

  @impl true
  def handle_call({:write, store, path, value, type, seq}, _from, state) do
    state = put_in(state.entries[{store, path}], {value, type, seq})
    current = Map.get(state.seqs, store, 0)
    state = put_in(state.seqs[store], max(current, seq))
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:write_batch, store, entries}, _from, state) do
    state =
      Enum.reduce(entries, state, fn {path, value, type, seq}, acc ->
        acc = put_in(acc.entries[{store, path}], {value, type, seq})
        current = Map.get(acc.seqs, store, 0)
        put_in(acc.seqs[store], max(current, seq))
      end)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:delete, store, path}, _from, state) do
    state = update_in(state.entries, &Map.delete(&1, {store, path}))
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:last_seq, store}, _from, state) do
    {:reply, Map.get(state.seqs, store, 0), state}
  end

  @impl true
  def handle_call({:count, store}, _from, state) do
    count =
      state.entries
      |> Enum.count(fn {{s, _path}, _} -> s == store end)

    {:reply, count, state}
  end

  @impl true
  def handle_call({:browse, store, opts}, _from, state) do
    pattern = Keyword.get(opts, :pattern, "**")
    cursor = Keyword.get(opts, :cursor)
    limit = Keyword.get(opts, :limit, 50)
    order = Keyword.get(opts, :order, :asc)
    select = Keyword.get(opts, :select, :entries)
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)

    compiled = Dust.Protocol.Glob.compile(pattern)

    entries =
      state.entries
      |> Enum.filter(fn {{s, path}, _} ->
        s == store and matches_filter?(path, pattern, compiled, from, to)
      end)
      |> Enum.map(fn {{_s, path}, {value, type, seq}} -> {path, value, type, seq} end)
      |> Enum.sort_by(fn {path, _, _, _} -> path end, sort_direction(order))

    entries = apply_cursor(entries, cursor, order)

    # Apply limit
    page = Enum.take(entries, limit)

    next_cursor =
      if length(page) < limit or length(page) == 0 do
        nil
      else
        {last_path, _, _, _} = List.last(page)
        last_path
      end

    projected = project_page(page, select, pattern)

    {:reply, {projected, next_cursor}, state}
  end

  defp project_page(page, :entries, _pattern), do: page
  defp project_page(page, :keys, _pattern), do: Enum.map(page, fn {p, _, _, _} -> p end)
  defp project_page(page, :prefixes, pattern), do: prefixes_of(page, pattern)

  defp prefixes_of(page, pattern) do
    literal_prefix = literal_prefix_of(pattern)

    page
    |> Enum.map(fn {p, _, _, _} -> extract_prefix(p, literal_prefix) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp literal_prefix_of("**"), do: ""

  defp literal_prefix_of(pattern) do
    case String.split(pattern, ".**", parts: 2) do
      [prefix, ""] ->
        prefix

      _ ->
        raise ArgumentError,
              "select: :prefixes requires pattern ending in .** or ** (got #{inspect(pattern)})"
    end
  end

  defp extract_prefix(path, "") do
    case String.split(path, ".", parts: 2) do
      [seg | _] -> seg
      [] -> nil
    end
  end

  defp extract_prefix(path, literal) do
    prefix_with_dot = literal <> "."

    if String.starts_with?(path, prefix_with_dot) do
      rest = String.replace_prefix(path, prefix_with_dot, "")
      [next_seg | _] = String.split(rest, ".", parts: 2)
      literal <> "." <> next_seg
    end
  end

  defp matches_filter?(path, _pattern, _compiled, from, to) when is_binary(from) and is_binary(to) do
    path >= from and path < to
  end

  defp matches_filter?(path, _pattern, compiled, _from, _to) do
    Dust.Protocol.Glob.match?(compiled, String.split(path, "."))
  end

  defp sort_direction(:asc), do: :asc
  defp sort_direction(:desc), do: :desc

  defp apply_cursor(entries, nil, _order), do: entries

  defp apply_cursor(entries, cursor, :asc),
    do: Enum.drop_while(entries, fn {p, _, _, _} -> p <= cursor end)

  defp apply_cursor(entries, cursor, :desc),
    do: Enum.drop_while(entries, fn {p, _, _, _} -> p >= cursor end)
end
