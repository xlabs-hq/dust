defmodule DustWeb.DevController do
  @moduledoc """
  Dev-only endpoints. These routes are mounted compile-time only when
  `Mix.env() == :dev`, so they cannot be hit in prod.
  """
  use DustWeb, :controller

  require Logger

  def client_error(conn, params) do
    %{
      "level" => level,
      "message" => message,
      "url" => url
    } = params

    stack = params["stack"]
    user_agent = get_req_header(conn, "user-agent") |> List.first()

    formatted =
      [
        "[client-#{level}] #{message}",
        "  url: #{url}",
        stack && "  stack:\n#{indent(stack)}",
        user_agent && "  user-agent: #{user_agent}"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    case level do
      "error" -> Logger.error(formatted)
      "warn" -> Logger.warning(formatted)
      _ -> Logger.info(formatted)
    end

    send_resp(conn, 204, "")
  end

  defp indent(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &("    " <> &1))
  end
end
