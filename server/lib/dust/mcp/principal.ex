defmodule Dust.MCP.Principal do
  @moduledoc """
  Unified authentication principal for the MCP endpoint.

  `:store_token` — legacy single-store bearer (`dust_tok_…`).
  `:user_session` — OAuth-issued opaque token bound to a user (multi-org).
  """

  defstruct [:kind, :user, :store_token, :session]

  @type kind :: :store_token | :user_session

  @type t :: %__MODULE__{
          kind: kind(),
          user: Dust.Accounts.User.t() | nil,
          store_token: Dust.Stores.StoreToken.t() | nil,
          session: Dust.MCP.Session.t() | nil
        }
end
