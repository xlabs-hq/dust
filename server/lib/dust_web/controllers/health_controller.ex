defmodule DustWeb.HealthController do
  use DustWeb, :controller

  def healthz(conn, _params) do
    json(conn, %{status: "ok"})
  end

  def readyz(conn, _params) do
    checks = %{
      database: safe_check(fn -> check_database() end),
      pubsub: safe_check(fn -> check_pubsub() end)
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
  end

  defp check_pubsub do
    case Phoenix.PubSub.node_name(Dust.PubSub) do
      name when is_atom(name) -> :ok
      _ -> :error
    end
  end

  # Run a check function, catching any crash (exit, throw, or error)
  defp safe_check(fun) do
    fun.()
  catch
    _, _ -> :error
  end
end
