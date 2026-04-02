defmodule DustWeb.HealthController do
  use DustWeb, :controller

  def healthz(conn, _params) do
    json(conn, %{status: "ok"})
  end

  def readyz(conn, _params) do
    checks = %{
      database: check_database(),
      pubsub: check_pubsub()
    }

    all_ok = Enum.all?(checks, fn {_, v} -> v == :ok end)

    if all_ok do
      json(conn, %{status: "ok", checks: Map.new(checks, fn {k, v} -> {k, to_string(v)} end)})
    else
      conn
      |> put_status(503)
      |> json(%{status: "unavailable", checks: Map.new(checks, fn {k, v} -> {k, to_string(v)} end)})
    end
  end

  defp check_database do
    case Ecto.Adapters.SQL.query(Dust.Repo, "SELECT 1") do
      {:ok, _} -> :ok
      {:error, _} -> :error
    end
  rescue
    _ -> :error
  end

  defp check_pubsub do
    case Phoenix.PubSub.node_name(Dust.PubSub) do
      name when is_atom(name) -> :ok
      _ -> :error
    end
  rescue
    _ -> :error
  end
end
