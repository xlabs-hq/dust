defmodule DustWeb.Api.Refs do
  @moduledoc """
  Pre-built `Oaskit.Spec.Reference` structs for the shared components
  defined in `DustWeb.ApiSpec`.

  Use as module attributes inside annotated controllers:

      @unauthorized DustWeb.Api.Refs.unauthorized()
      @entry_ref DustWeb.Api.Refs.schema("Entry")

  Avoids hand-typing the struct literal `%Oaskit.Spec.Reference{:"$ref" => ...}`
  in every operation.
  """

  alias Oaskit.Spec.Reference

  defp ref(target), do: %Reference{:"$ref" => target}

  def schema(name), do: ref("#/components/schemas/#{name}")
  def response(name), do: ref("#/components/responses/#{name}")
  def parameter(name), do: ref("#/components/parameters/#{name}")

  # Common shorthands
  def unauthorized, do: response("Unauthorized")
  def forbidden, do: response("Forbidden")
  def not_found, do: response("NotFound")
  def bad_request, do: response("BadRequest")
  def rate_limited, do: response("RateLimited")
end

# JSV's normalizer doesn't have a built-in impl for Oaskit.Spec.Reference,
# so the spec controller blows up at serialisation time when we use ref
# structs in responses/parameters. Convert to a plain map with the keys
# OpenAPI expects.
defimpl JSV.Normalizer.Normalize, for: Oaskit.Spec.Reference do
  def normalize(%Oaskit.Spec.Reference{} = ref) do
    %{"$ref" => Map.get(ref, :"$ref")}
    |> maybe_put("summary", Map.get(ref, :summary))
    |> maybe_put("description", Map.get(ref, :description))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
