defmodule Dust.Files.Blob do
  @moduledoc "Schema for tracking content-addressed blobs and their reference counts."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:hash, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "blobs" do
    field :size, :integer
    field :content_type, :string
    field :filename, :string
    field :reference_count, :integer, default: 1

    timestamps()
  end

  def changeset(blob, attrs) do
    blob
    |> cast(attrs, [:hash, :size, :content_type, :filename, :reference_count])
    |> validate_required([:hash, :size])
  end
end
