defmodule DustWeb.Api.FallbackController do
  use DustWeb, :controller

  def call(conn, {:error, :not_found}),
    do: conn |> put_status(404) |> json(%{error: "not_found"})

  def call(conn, {:error, :org_mismatch}),
    do: conn |> put_status(404) |> json(%{error: "not_found"})

  def call(conn, {:error, :forbidden}),
    do: conn |> put_status(403) |> json(%{error: "forbidden"})

  def call(conn, {:error, {:invalid_params, detail}}),
    do: conn |> put_status(400) |> json(%{error: "invalid_params", detail: detail})

  def call(conn, {:error, {:conflicting_params, detail}}),
    do: conn |> put_status(400) |> json(%{error: "conflicting_params", detail: detail})
end
