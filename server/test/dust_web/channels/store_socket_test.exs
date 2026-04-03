defmodule DustWeb.StoreSocketTest do
  use Dust.DataCase, async: false
  import Phoenix.ChannelTest

  alias Dust.{Accounts, Stores}

  @endpoint DustWeb.Endpoint

  setup do
    {:ok, user} = Accounts.create_user(%{email: "socket_test@example.com"})

    {:ok, org} =
      Accounts.create_organization_with_owner(user, %{name: "SocketOrg", slug: "socketorg"})

    {:ok, store} = Stores.create_store(org, %{name: "socketstore"})

    {:ok, token} =
      Stores.create_store_token(store, %{
        name: "rw",
        read: true,
        write: true,
        created_by_id: user.id
      })

    %{raw_token: token.raw_token}
  end

  describe "connect/3" do
    test "connects with valid capver string", %{raw_token: raw_token} do
      socket = socket(DustWeb.StoreSocket, "test", %{})

      params = %{
        "token" => raw_token,
        "device_id" => "dev_1",
        "capver" => "1"
      }

      assert {:ok, socket} = DustWeb.StoreSocket.connect(params, socket, %{})
      assert socket.assigns.capver == 1
    end

    test "rejects connection when capver is below minimum", %{raw_token: raw_token} do
      socket = socket(DustWeb.StoreSocket, "test", %{})

      params = %{
        "token" => raw_token,
        "device_id" => "dev_1",
        "capver" => "0"
      }

      assert :error = DustWeb.StoreSocket.connect(params, socket, %{})
    end

    test "accepts connection when capver is missing (defaults to 1)", %{raw_token: raw_token} do
      socket = socket(DustWeb.StoreSocket, "test", %{})

      params = %{
        "token" => raw_token,
        "device_id" => "dev_1"
      }

      assert {:ok, socket} = DustWeb.StoreSocket.connect(params, socket, %{})
      assert socket.assigns.capver == 1
    end

    test "stores capver as integer in socket assigns", %{raw_token: raw_token} do
      socket = socket(DustWeb.StoreSocket, "test", %{})

      params = %{
        "token" => raw_token,
        "device_id" => "dev_1",
        "capver" => "1"
      }

      assert {:ok, socket} = DustWeb.StoreSocket.connect(params, socket, %{})
      assert is_integer(socket.assigns.capver)
    end

    test "rejects connection with invalid token" do
      socket = socket(DustWeb.StoreSocket, "test", %{})

      params = %{
        "token" => "dust_invalid_token",
        "device_id" => "dev_1",
        "capver" => "1"
      }

      assert :error = DustWeb.StoreSocket.connect(params, socket, %{})
    end

    test "rejects connection when token is missing" do
      socket = socket(DustWeb.StoreSocket, "test", %{})

      params = %{"device_id" => "dev_1", "capver" => "1"}

      assert :error = DustWeb.StoreSocket.connect(params, socket, %{})
    end

    test "defaults unparseable capver to 1", %{raw_token: raw_token} do
      socket = socket(DustWeb.StoreSocket, "test", %{})

      params = %{
        "token" => raw_token,
        "device_id" => "dev_1",
        "capver" => "not_a_number"
      }

      assert {:ok, socket} = DustWeb.StoreSocket.connect(params, socket, %{})
      assert socket.assigns.capver == 1
    end
  end
end
