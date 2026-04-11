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
end
