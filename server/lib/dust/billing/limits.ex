defmodule Dust.Billing.Limits do
  @moduledoc """
  Plan limits for billing enforcement. No Stripe — just the rules.
  """

  @plans %{
    "free" => %{
      stores: 1,
      keys_per_store: 1_000,
      file_storage_bytes: 100_000_000,
      retention_days: 7
    },
    "pro" => %{
      stores: :unlimited,
      keys_per_store: 100_000,
      file_storage_bytes: 10_000_000_000,
      retention_days: 30
    },
    "team" => %{
      stores: :unlimited,
      keys_per_store: 1_000_000,
      file_storage_bytes: 100_000_000_000,
      retention_days: 365
    }
  }

  def for_plan(plan) when is_binary(plan) do
    Map.get(@plans, plan, @plans["free"])
  end

  def check_store_count(organization) do
    limits = for_plan(organization.plan || "free")

    case limits.stores do
      :unlimited ->
        :ok

      max_stores ->
        current = Dust.Stores.store_count(organization)

        if current < max_stores do
          :ok
        else
          {:error, :limit_exceeded, %{dimension: :stores, current: current, limit: max_stores}}
        end
    end
  end

  def check_key_count(store_id, new_key_count, organization) do
    limits = for_plan(organization.plan || "free")
    max_keys = limits.keys_per_store
    current = Dust.Sync.entry_count(store_id)

    if current + new_key_count <= max_keys do
      :ok
    else
      {:error, :limit_exceeded, %{dimension: :keys, current: current, limit: max_keys}}
    end
  end

  def check_file_storage(store_id, new_bytes, organization) do
    limits = for_plan(organization.plan || "free")
    max_bytes = limits.file_storage_bytes
    current = Dust.Files.store_usage_bytes(store_id)

    if current + new_bytes <= max_bytes do
      :ok
    else
      {:error, :limit_exceeded, %{dimension: :file_storage, current: current, limit: max_bytes}}
    end
  end
end
