defmodule Dust.StoresTest do
  use Dust.DataCase, async: true

  alias Dust.{Accounts, Stores}

  setup do
    {:ok, user} = Accounts.create_user(%{email: "test@example.com"})
    {:ok, org} = Accounts.create_organization_with_owner(user, %{name: "James", slug: "james"})
    %{user: user, org: org}
  end

  describe "stores" do
    test "create and retrieve by full name", %{org: org} do
      {:ok, store} = Stores.create_store(org, %{name: "blog"})
      assert store.name == "blog"

      found = Stores.get_store_by_full_name("james/blog")
      assert found.id == store.id
    end

    test "full name lookup returns nil for nonexistent store" do
      assert Stores.get_store_by_full_name("james/nope") == nil
    end
  end

  describe "tokens" do
    test "create and authenticate", %{org: org, user: user} do
      {:ok, store} = Stores.create_store(org, %{name: "blog"})
      {:ok, token} = Stores.create_store_token(store, %{name: "test", read: true, write: true, created_by_id: user.id})

      assert String.starts_with?(token.raw_token, "dust_tok_")

      {:ok, authed} = Stores.authenticate_token(token.raw_token)
      assert authed.store_id == store.id
      assert Stores.StoreToken.can_read?(authed)
      assert Stores.StoreToken.can_write?(authed)
    end

    test "rejects invalid token" do
      assert {:error, :invalid_token} = Stores.authenticate_token("dust_tok_bogus")
    end

    test "rejects non-prefixed token" do
      assert {:error, :invalid_token} = Stores.authenticate_token("not_a_token")
    end
  end

  describe "devices" do
    test "ensure_device creates on first call" do
      {:ok, device} = Stores.ensure_device("dev_abc")
      assert device.device_id == "dev_abc"
    end

    test "ensure_device updates last_seen on second call" do
      {:ok, first} = Stores.ensure_device("dev_abc")
      {:ok, second} = Stores.ensure_device("dev_abc")
      assert second.id == first.id
    end
  end
end
