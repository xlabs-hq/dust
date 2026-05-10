defmodule DustEcto.Test.Schemas do
  @moduledoc "Schemas used across the test suite."
end

defmodule DustEcto.Test.Link do
  @moduledoc false
  use DustEcto.Schema,
    prefix: "links",
    required: [:slug, :title, :url]

  embedded_schema do
    field :title, :string
    field :url, :string
    field :note, :string
    field :added_at, :utc_datetime
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [:slug, :title, :url, :note, :added_at])
    |> validate_required(__dust_required_fields__())
    |> validate_dust_slug(:slug)
  end
end

defmodule DustEcto.Test.FlatNote do
  @moduledoc false
  use DustEcto.Schema,
    prefix: "notes",
    required: [:slug, :body],
    mode: :flat

  embedded_schema do
    field :body, :string
  end

  def changeset(note, attrs) do
    note
    |> cast(attrs, [:slug, :body])
    |> validate_required(__dust_required_fields__())
    |> validate_dust_slug(:slug)
  end
end
