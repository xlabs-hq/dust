defmodule DustWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use DustWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint DustWeb.Endpoint

      use DustWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import DustWeb.ConnCase
    end
  end

  setup tags do
    Dust.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Logs the given `user` into the `conn` by setting `:user_token` in the
  session, mirroring `DustWeb.WorkOSAuthController.log_in_user/2`.
  """
  def log_in_user(conn, user) do
    token = Dust.Accounts.generate_user_session_token(user)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  @doc """
  Allowlists the given `uri` for the MCP OAuth redirect_uri validator and
  ensures the env var is cleaned up after the test.
  """
  def put_allowlisted_redirect(conn, uri) do
    previous = Application.get_env(:dust, :mcp_redirect_uri_allowlist, [])
    Application.put_env(:dust, :mcp_redirect_uri_allowlist, [uri | previous])

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:dust, :mcp_redirect_uri_allowlist, previous)
    end)

    conn
  end
end
