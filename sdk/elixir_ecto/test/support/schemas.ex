defmodule DustEcto.Test.Schemas do
  @moduledoc "Schemas used across the test suite."
end

defmodule DustEcto.Test.Link do
  @moduledoc false
  use DustEcto.Schema,
    prefix: ["links"],
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

defmodule DustEcto.Test.MapLink do
  @moduledoc """
  Explicit `mode: :map` schema for the atomic-write code path. The
  default mode is `:flat` (post-trial-r2 flip), so we keep this schema
  around to exercise `:map` writes specifically.
  """
  use DustEcto.Schema,
    prefix: ["map_links"],
    required: [:slug, :title, :url],
    mode: :map

  embedded_schema do
    field :title, :string
    field :url, :string
    field :note, :string
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [:slug, :title, :url, :note])
    |> validate_required(__dust_required_fields__())
    |> validate_dust_slug(:slug)
  end
end

defmodule DustEcto.Test.FlatNote do
  @moduledoc false
  use DustEcto.Schema,
    prefix: ["notes"],
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

defmodule DustEcto.Test.DottedPrefixLink do
  @moduledoc """
  Regression schema for multi-segment prefixes — what used to be
  `prefix: "reading.links"` (legacy dotted) is now an explicit list
  of segments. Path parsing has to walk segment-by-segment rather
  than naively dot-splitting.
  """
  use DustEcto.Schema,
    prefix: ["reading", "links"],
    required: [:slug, :title]

  embedded_schema do
    field :title, :string
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [:slug, :title])
    |> validate_required(__dust_required_fields__())
    |> validate_dust_slug(:slug)
  end
end

defmodule DustEcto.Test.NestedThing do
  @moduledoc """
  Regression schema for nested map-typed fields. The server flattens
  `meta: %{a: 1, b: 2}` to entries `things.foo.meta.a` and
  `things.foo.meta.b`; reads have to reassemble the nested shape.
  """
  use DustEcto.Schema,
    prefix: ["things"],
    required: [:slug]

  embedded_schema do
    field :meta, :map
  end

  def changeset(thing, attrs) do
    thing
    |> cast(attrs, [:slug, :meta])
    |> validate_required(__dust_required_fields__())
    |> validate_dust_slug(:slug)
  end
end
