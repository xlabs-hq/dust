defmodule Dust.Stores.Device do
  use Dust.Schema

  schema "devices" do
    field :device_id, :string
    field :name, :string
    field :last_seen_at, :utc_datetime_usec

    belongs_to :user, Dust.Accounts.User

    timestamps()
  end

  def changeset(device, attrs) do
    device
    |> Ecto.Changeset.cast(attrs, [:device_id, :name, :user_id])
    |> Ecto.Changeset.validate_required([:device_id])
    |> Ecto.Changeset.unique_constraint(:device_id)
  end
end
