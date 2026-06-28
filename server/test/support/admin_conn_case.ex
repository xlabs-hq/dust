defmodule AdminWeb.ConnCase do
  @moduledoc """
  Test case for tests that exercise the AdminWeb endpoint.

  Mirrors `DustWeb.ConnCase` but targets `AdminWeb.Endpoint`. The admin
  interface has no application-level authentication (access is gated by
  port/network isolation), so there is no `log_in_user/2` helper here.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint AdminWeb.Endpoint

      use AdminWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
    end
  end

  setup tags do
    Dust.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
