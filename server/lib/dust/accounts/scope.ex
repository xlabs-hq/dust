defmodule Dust.Accounts.Scope do
  alias Dust.Accounts.{User, Organization}

  defstruct user: nil, organization: nil, api_key: nil

  def for_user(%User{} = user), do: %__MODULE__{user: user}
  def for_user(nil), do: nil

  def put_organization(%__MODULE__{} = scope, %Organization{} = org) do
    %{scope | organization: org}
  end
end
