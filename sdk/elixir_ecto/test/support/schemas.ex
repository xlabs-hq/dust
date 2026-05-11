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

defmodule DustEcto.Test.DottedPrefixLink do
  @moduledoc """
  Regression schema for dotted-prefix support — prefix itself contains
  a `.`, so `parse_path` has to walk the path one prefix-segment at a
  time rather than splitting and pattern-matching on exact arity.
  """
  use DustEcto.Schema,
    prefix: "reading.links",
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
    prefix: "things",
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
