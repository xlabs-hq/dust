defmodule Dust.IntegrationHelpers do
  alias Dust.{Accounts, Stores}

  @doc "Create a user, org, store, and read-write token. Returns a map with all entities."
  def create_test_store(org_slug \\ "test", store_name \\ "blog") do
    {:ok, user} = Accounts.create_user(%{email: "#{org_slug}@example.com"})
    {:ok, org} = Accounts.create_organization_with_owner(user, %{name: org_slug, slug: org_slug})
    {:ok, store} = Stores.create_store(org, %{name: store_name})

    {:ok, token} =
      Stores.create_store_token(store, %{
        name: "test",
        read: true,
        write: true,
        created_by_id: user.id
      })

    %{user: user, org: org, store: store, token: token}
  end

  @doc "Connect a Phoenix Channel test client to a store."
  def connect_client(token, store, device_id, last_seq \\ 0) do
    # Call the underlying function directly (the macro requires @endpoint module attribute)
    {:ok, socket} =
      Phoenix.ChannelTest.__connect__(DustWeb.Endpoint, DustWeb.StoreSocket, %{
        "token" => token.raw_token,
        "device_id" => device_id,
        "capver" => 1
      }, [])

    {:ok, reply, socket} =
      Phoenix.ChannelTest.subscribe_and_join(
        socket,
        DustWeb.StoreChannel,
        "store:#{store.id}",
        %{"last_store_seq" => last_seq}
      )

    {socket, reply}
  end
end
