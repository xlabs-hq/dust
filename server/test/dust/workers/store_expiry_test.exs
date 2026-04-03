defmodule Dust.Workers.StoreExpiryTest do
  use Dust.DataCase, async: false
  use Oban.Testing, repo: Dust.Repo

  import Ecto.Query

  alias Dust.{Accounts, Stores}

  setup do
    {:ok, user} = Accounts.create_user(%{email: "expiry@example.com"})

    {:ok, org} =
      Accounts.create_organization_with_owner(user, %{name: "Test", slug: "expirytest"})

    org |> Ecto.Changeset.change(plan: "pro") |> Dust.Repo.update!()
    %{org: org}
  end

  test "archives expired stores", %{org: org} do
    # Create a store that expired 1 minute ago
    {:ok, store} = Stores.create_store(org, %{name: "expired", ttl: 1})
    # Manually set expires_at to the past
    past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:microsecond)

    Dust.Repo.update_all(
      from(s in Stores.Store, where: s.id == ^store.id),
      set: [expires_at: past]
    )

    :ok = perform_job(Dust.Workers.StoreExpiry, %{})

    updated = Dust.Repo.get!(Stores.Store, store.id)
    assert updated.status == :archived
  end

  test "does not archive permanent stores", %{org: org} do
    {:ok, store} = Stores.create_store(org, %{name: "permanent"})

    :ok = perform_job(Dust.Workers.StoreExpiry, %{})

    updated = Dust.Repo.get!(Stores.Store, store.id)
    assert updated.status == :active
  end

  test "does not archive non-expired ephemeral stores", %{org: org} do
    {:ok, store} = Stores.create_store(org, %{name: "future", ttl: 3600})

    :ok = perform_job(Dust.Workers.StoreExpiry, %{})

    updated = Dust.Repo.get!(Stores.Store, store.id)
    assert updated.status == :active
  end
end
