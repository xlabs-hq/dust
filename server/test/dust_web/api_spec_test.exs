defmodule DustWeb.ApiSpecTest do
  @moduledoc """
  Sanity checks on the generated OpenAPI spec. Catches drift between
  the router and the operation annotations, and ensures the spec stays
  publishable (no Phoenix-specific glob captures, every operation
  has an explicit operationId, every API route is documented).
  """
  use ExUnit.Case, async: true

  setup_all do
    {:ok, spec: DustWeb.ApiSpec.spec()}
  end

  test "no path uses Phoenix glob captures (`*name`)", %{spec: spec} do
    bad = for {path, _} <- spec[:paths], String.contains?(path, "*"), do: path
    assert bad == [], "paths must use {param} not *param: #{inspect(bad)}"
  end

  test "every path parameter declared in the URL is documented", %{spec: spec} do
    failures =
      for {path, methods} <- spec[:paths],
          {verb, op} <- methods,
          is_map(op) do
        params = Map.get(op, :parameters, []) || []
        path_params = path_param_names(path)

        documented =
          params
          |> Enum.map(&parameter_name(&1, spec))
          |> Enum.reject(&is_nil/1)
          |> MapSet.new()

        missing = MapSet.difference(MapSet.new(path_params), documented)

        if MapSet.size(missing) > 0 do
          ["#{verb |> to_string() |> String.upcase()} #{path}: missing #{inspect(MapSet.to_list(missing))}"]
        else
          []
        end
      end
      |> List.flatten()

    assert failures == [], Enum.join(failures, "\n")
  end

  test "every operation has an explicit operationId (no generated hash)", %{spec: spec} do
    bad =
      for {path, methods} <- spec[:paths],
          {verb, op} <- methods,
          is_map(op),
          op_id = Map.get(op, :operationId),
          op_id == nil or String.match?(op_id, ~r/_[A-Z0-9]{6,}$/) do
        "#{verb |> to_string() |> String.upcase()} #{path}: #{inspect(op_id)}"
      end

    assert bad == [], "operationIds must be set explicitly:\n" <> Enum.join(bad, "\n")
  end

  test "every /api/* route in the router is documented", %{spec: spec} do
    documented_paths = MapSet.new(Map.keys(spec[:paths]))

    router_paths =
      DustWeb.Router.__routes__()
      |> Enum.filter(fn route ->
        is_atom(route.plug_opts) and String.starts_with?(route.path, "/api/")
      end)
      |> Enum.map(&phoenix_path_to_openapi(&1.path))
      |> MapSet.new()

    missing = MapSet.difference(router_paths, documented_paths)
    assert MapSet.size(missing) == 0, "router has paths not in spec: #{inspect(missing)}"
  end

  test "the spec serialises cleanly to JSON" do
    json = Oaskit.to_json!(DustWeb.ApiSpec)
    refute json =~ "Oaskit.Spec.Reference"
    refute json =~ "\"Elixir."
    decoded = Jason.decode!(json)
    assert decoded["openapi"] == "3.1.1"
    assert is_map(decoded["paths"])
    assert is_map(decoded["components"]["schemas"])
  end

  # --- helpers ---

  defp path_param_names(path) do
    Regex.scan(~r/\{(\w+)\}/, path, capture: :all_but_first)
    |> List.flatten()
  end

  defp phoenix_path_to_openapi(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", fn
      ":" <> name -> "{#{name}}"
      "*" <> name -> "{#{name}}"
      seg -> seg
    end)
  end

  defp parameter_name(%Oaskit.Spec.Reference{} = ref, spec) do
    case Map.get(ref, :"$ref") do
      "#/components/parameters/" <> name ->
        get_in(spec, [:components, :parameters, name, :name]) ||
          get_in(spec, [:components, :parameters, name])[:name]

      _ ->
        nil
    end
  end

  defp parameter_name(%{name: name}, _spec) when is_binary(name), do: name
  defp parameter_name(%{name: name}, _spec) when is_atom(name), do: Atom.to_string(name)
  defp parameter_name(_, _), do: nil
end
