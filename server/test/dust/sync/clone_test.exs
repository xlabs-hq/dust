defmodule Dust.Sync.CloneTest do
  use Dust.DataCase, async: false

  alias Dust.{Accounts, Stores, Sync}

  setup do
    {:ok, user} = Accounts.create_user(%{email: "clone@example.com"})

    {:ok, org} =
      Accounts.create_organization_with_owner(user, %{name: "Clone Co", slug: "cloneco"})

    # Upgrade to pro plan so we can create multiple stores
    org |> Ecto.Changeset.change(plan: "pro") |> Dust.Repo.update!()
    org = Dust.Repo.reload!(org)
    {:ok, source} = Stores.create_store(org, %{name: "source"})
    %{org: org, source: source}
  end

  describe "clone_store/3" do
    test "clones store data to a new store", %{org: org, source: source} do
      Sync.write(source.id, %{
        op: :set,
        path: "a",
        value: "hello",
        device_id: "d",
        client_op_id: "o1"
      })

      Sync.write(source.id, %{
        op: :set,
        path: "b.c",
        value: 42,
        device_id: "d",
        client_op_id: "o2"
      })

      assert {:ok, target} = Sync.Clone.clone_store(source, org, "cloned")

      assert target.name == "cloned"

      # Entries should exist in the target
      assert Sync.get_entry(target.id, "a").value == "hello"
      assert Sync.get_entry(target.id, "b.c").value == 42
    end

    test "preserves seq numbers", %{org: org, source: source} do
      Sync.write(source.id, %{op: :set, path: "x", value: 1, device_id: "d", client_op_id: "o1"})
      Sync.write(source.id, %{op: :set, path: "y", value: 2, device_id: "d", client_op_id: "o2"})
      Sync.write(source.id, %{op: :set, path: "z", value: 3, device_id: "d", client_op_id: "o3"})

      {:ok, target} = Sync.Clone.clone_store(source, org, "seq-clone")

      # Reload from Postgres to check metadata
      target = Stores.get_store!(target.id)
      source = Stores.get_store!(source.id)

      assert target.current_seq == source.current_seq
      assert target.entry_count == source.entry_count
      assert target.op_count == source.op_count
    end

    test "returns error when target name already exists", %{org: org, source: source} do
      Stores.create_store(org, %{name: "taken"})

      assert {:error, %Ecto.Changeset{}} = Sync.Clone.clone_store(source, org, "taken")
    end
  end
end
