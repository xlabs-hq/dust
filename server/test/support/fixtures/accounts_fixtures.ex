defmodule Dust.AccountsFixtures do
  @moduledoc """
  Fixtures for `Dust.Accounts`.
  """

  alias Dust.Accounts

  def unique_user_email,
    do: "user-#{System.unique_integer([:positive])}@example.com"

  def user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> Enum.into(%{email: unique_user_email()})
      |> Accounts.create_user()

    user
  end
end
