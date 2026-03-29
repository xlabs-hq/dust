defmodule Dust.CallbackRegistry do
  def new do
    :ets.new(:dust_callbacks, [:bag, :public])
  end

  def register(table, store, pattern, callback) when is_function(callback, 1) do
    ref = make_ref()
    compiled = DustProtocol.Glob.compile(pattern)
    :ets.insert(table, {store, compiled, pattern, callback, ref})
    ref
  end

  def unregister(table, ref) do
    :ets.match_delete(table, {:_, :_, :_, :_, ref})
    :ok
  end

  def match(table, store, path) do
    path_segments = String.split(path, ".")

    :ets.lookup(table, store)
    |> Enum.filter(fn {_store, compiled, _pattern, _callback, _ref} ->
      DustProtocol.Glob.match?(compiled, path_segments)
    end)
    |> Enum.map(fn {_store, _compiled, _pattern, callback, _ref} -> callback end)
  end
end
