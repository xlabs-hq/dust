defmodule Dust.Sync.Conflict do
  @moduledoc """
  In-memory replay helpers used by the snapshot/catch-up code. Paths
  are canonical rendered slash strings (the same shape stored in
  SQLite); child paths are built through `DustProtocol.Path.child/2`
  so map keys containing `.` or `/` survive intact.
  """

  alias DustProtocol.Path

  @doc "Apply a set operation to the entry map. Replaces value at path and removes descendants."
  def apply_set(entries, path, value, type) do
    {:ok, segments} = Path.parse_rendered(path)

    entries
    |> remove_descendants(segments)
    |> Map.put(path, %{value: value, type: type})
  end

  @doc "Apply a delete operation. Removes the path and all descendants."
  def apply_delete(entries, path) do
    {:ok, segments} = Path.parse_rendered(path)

    entries
    |> Map.delete(path)
    |> remove_descendants(segments)
  end

  @doc "Apply a merge operation. Updates named children, leaves siblings alone."
  def apply_merge(entries, path, map, child_type) when is_map(map) do
    {:ok, prefix_segments} = Path.parse_rendered(path)

    Enum.reduce(map, entries, fn {key, value}, acc ->
      {:ok, child_segments} = Path.child(prefix_segments, to_string(key))
      {:ok, child_path} = Path.render(child_segments)
      Map.put(acc, child_path, %{value: value, type: child_type})
    end)
  end

  defp remove_descendants(entries, ancestor_segments) do
    Map.reject(entries, fn {entry_path, _} ->
      case Path.parse_rendered(entry_path) do
        {:ok, entry_segments} -> Path.ancestor?(ancestor_segments, entry_segments)
        _ -> false
      end
    end)
  end
end
