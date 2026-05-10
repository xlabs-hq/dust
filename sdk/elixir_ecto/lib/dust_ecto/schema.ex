defmodule DustEcto.Schema do
  @moduledoc """
  `use DustEcto.Schema, prefix: "links", required: [:slug, :title]`
  pairs an `Ecto.Schema` (embedded) with a Dust prefix and the slug
  field used as the per-record namespace key.

  ## Usage

      defmodule MyApp.Reading.Link do
        use DustEcto.Schema,
          prefix: "links",                  # required
          required: [:slug, :title, :url],  # used by changeset + Repo.all guard
          mode: :map                        # :map (default) | :flat

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

  Records are stored under `<prefix>.<slug>.<field>` regardless of
  mode; the modes differ in how writes are issued (one PUT vs N PUTs).

  ## What the macro provides

  - `use Ecto.Schema` + `import Ecto.Changeset`
  - `@primary_key {:slug, :string, autogenerate: false}`
  - `__dust_prefix__/0` — the prefix string
  - `__dust_mode__/0` — `:map` or `:flat`
  - `__dust_required_fields__/0` — the `:required` list, used by both
    the user's `validate_required` *and* `DustEcto.Repo.all/1`'s
    read-time guard so they stay in sync. Necessary because Ecto's
    `validate_required` is a runtime check with no introspectable
    metadata.
  - `validate_dust_slug/2` — closes path-shape footguns by rejecting
    empty slugs, slugs containing `.` (would mis-shape the record at
    storage), and slugs containing `/` (URL/path ambiguity).
  """

  defmacro __using__(opts) do
    prefix = Keyword.fetch!(opts, :prefix)
    required = Keyword.get(opts, :required, [])
    mode = Keyword.get(opts, :mode, :map)

    unless is_binary(prefix) and prefix != "" do
      raise ArgumentError,
            "DustEcto.Schema requires a non-empty :prefix string (got #{inspect(prefix)})"
    end

    unless mode in [:map, :flat] do
      raise ArgumentError,
            "DustEcto.Schema :mode must be :map or :flat (got #{inspect(mode)})"
    end

    unless is_list(required) and Enum.all?(required, &is_atom/1) do
      raise ArgumentError,
            "DustEcto.Schema :required must be a list of field atoms (got #{inspect(required)})"
    end

    quote do
      use Ecto.Schema
      import Ecto.Changeset
      import DustEcto.Schema, only: [validate_dust_slug: 2]

      @primary_key {:slug, :string, autogenerate: false}

      def __dust_prefix__, do: unquote(prefix)
      def __dust_mode__, do: unquote(mode)
      def __dust_required_fields__, do: unquote(required)
    end
  end

  @doc """
  Validates that the given slug field is non-empty and does not contain
  characters that would mis-shape the record at the storage layer (`.`)
  or create URL-encoding ambiguity (`/`).

  Use inside any `changeset/2`:

      |> validate_dust_slug(:slug)
  """
  @spec validate_dust_slug(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_dust_slug(%Ecto.Changeset{} = changeset, field) when is_atom(field) do
    case Ecto.Changeset.get_field(changeset, field) do
      nil ->
        # Required-ness is enforced separately by validate_required; we
        # only validate the *shape* of a present slug here.
        changeset

      "" ->
        Ecto.Changeset.add_error(changeset, field, "cannot be empty")

      slug when is_binary(slug) ->
        cond do
          String.contains?(slug, ".") ->
            Ecto.Changeset.add_error(
              changeset,
              field,
              "cannot contain '.' (would mis-shape the record's path)"
            )

          String.contains?(slug, "/") ->
            Ecto.Changeset.add_error(
              changeset,
              field,
              "cannot contain '/' (URL path separator)"
            )

          true ->
            changeset
        end

      _other ->
        Ecto.Changeset.add_error(changeset, field, "must be a string")
    end
  end
end
