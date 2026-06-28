defmodule Dust.AccessTokens.ScopeGrant do
  use Ecto.Schema

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "api_token_scopes" do
    field :scope, :string

    belongs_to :token, Dust.AccessTokens.Token

    timestamps()
  end
end
