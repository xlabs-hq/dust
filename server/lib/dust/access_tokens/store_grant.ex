defmodule Dust.AccessTokens.StoreGrant do
  use Ecto.Schema

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "api_token_store_grants" do
    belongs_to :token, Dust.AccessTokens.Token
    belongs_to :organization, Dust.Accounts.Organization
    belongs_to :store, Dust.Stores.Store

    timestamps()
  end
end
