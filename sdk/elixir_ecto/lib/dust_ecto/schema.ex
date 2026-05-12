defmodule DustEcto.Schema do
  @moduledoc """
  `use DustEcto.Schema, prefix: ["links"], required: [:slug, :title]`
  pairs an `Ecto.Schema` (embedded) with a Dust prefix and the slug
  field used as the per-record namespace key.

  ## Usage

      defmodule MyApp.Reading.Link do
        use DustEcto.Schema,
          prefix: ["links"],                # required: segment list
          required: [:slug, :title, :url],  # used by changeset + Repo.all guard
          mode: :flat                       # :flat (default) | :map

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

  Multi-segment prefixes are a non-empty list of segments. Earlier
  versions accepted a dotted string (`"reading.links"`); after the
  segment-first migration, this must be an explicit list
  (`["reading", "links"]`) so dots in segments survive intact.

  ## Storage modes

  Pick `:flat` (the default) unless you know you want `:map`.

  **`:flat` (default)** — one PUT per field; record lives on the wire as
  N leaves at `<prefix>/<slug>/<field>` (canonical slash form). This
  is the natural Dust shape: other writers (MCP, curl, sibling clients)
  can edit a single field without knowing the rest of the record, and
  per-field subscriptions are granular. Cost: writes are not atomic
  across fields; a partial update is observable until the last PUT
  lands.

  **`:map`** — one PUT for the whole record at `<prefix>/<slug>`, with
  the dumped struct as the value. Atomic, single revision per record.
  Cost: writes from outside the schema (a curl that PUTs
  `links/foo/title` directly) race with the next `:map` write that
  clobbers the whole record. Use when *you are the only writer* and you
  need whole-record atomicity.

  Reads work identically in both modes — Dust stores everything as flat
  leaves on disk, and `Repo.get/2` GETs the slug path which the server
  assembles back to a map.

  ## What the macro provides

  - `use Ecto.Schema` + `import Ecto.Changeset`
  - `@primary_key {:slug, :string, autogenerate: false}`
  - `__dust_prefix__/0` — the prefix segment list (`["reading", "links"]`)
  - `__dust_mode__/0` — `:flat` (default) or `:map`
  - `__dust_required_fields__/0` — the `:required` list, used by both
    the user's `validate_required` *and* `DustEcto.Repo.all/1`'s
    read-time guard so they stay in sync. Necessary because Ecto's
    `validate_required` is a runtime check with no introspectable
    metadata.
  - `validate_dust_slug/2` — closes path-shape footguns by rejecting
    empty slugs, slugs containing `.` (would mis-shape a *legacy*
    record path; harmless under segment-first storage but still
    rejected for clarity), and slugs containing `/` (would conflict
    with the canonical slash separator).
  """

  defmacro __using__(opts) do
    prefix = Keyword.fetch!(opts, :prefix)
    required = Keyword.get(opts, :required, [])
    mode = Keyword.get(opts, :mode, :flat)

    case validate_prefix(prefix) do
      :ok ->
        :ok

      {:error, reason} ->
        raise ArgumentError, reason
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

      @doc """
      All field names declared in `embedded_schema`, including the
      `:slug` primary key. Used by `DustEcto.Repo` for read-time
      validation and flat-mode writes.
      """
      def __dust_field_names__, do: __schema__(:fields)
    end
  end

  # Validate the `:prefix` schema option. Returns `:ok` for a
  # non-empty list of non-empty binaries; otherwise an `{:error,
  # reason}` tuple with a migration-friendly message that points
  # legacy dotted-string callers at the new contract.
  @doc false
  def validate_prefix(prefix) do
    cond do
      is_binary(prefix) ->
        suggested =
          case prefix do
            "" -> "[]"
            s when is_binary(s) -> inspect(String.split(s, "."))
          end

        {:error,
         "DustEcto.Schema :prefix is now a segment list, not a string. " <>
           "Replace `prefix: #{inspect(prefix)}` with `prefix: #{suggested}`. " <>
           "(Segment-first paths landed in capver 3; see " <>
           "docs/plans/2026-05-12-segment-first-paths.md.)"}

      not is_list(prefix) ->
        {:error,
         "DustEcto.Schema :prefix must be a non-empty list of non-empty strings (got #{inspect(prefix)})"}

      prefix == [] ->
        {:error, "DustEcto.Schema :prefix must not be empty"}

      not Enum.all?(prefix, &(is_binary(&1) and &1 != "")) ->
        {:error,
         "DustEcto.Schema :prefix segments must be non-empty strings (got #{inspect(prefix)})"}

      true ->
        :ok
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
