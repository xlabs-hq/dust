defmodule DustEcto do
  @moduledoc """
  Ecto-shaped facade over Dust — `DustEcto.Schema` plus `DustEcto.Repo`,
  designed to feel like the parts of `Ecto.Schema` and `Ecto.Repo` that
  map cleanly onto Dust's flat KV model.

  See the design doc at `docs/plans/2026-05-10-dust-ecto-design.md` in
  the dust monorepo for the rationale, scope, and trade-offs.

  ## Quick start

      defmodule MyApp.Reading.Link do
        use DustEcto.Schema,
          prefix: ["links"],
          required: [:slug, :title, :url]

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

      # Configure once at startup:
      #   config :dustlayer_ecto,
      #     store: System.get_env("DUST_STORE"),
      #     dust_facade: MyApp.Dust   # WS-mode (recommended)
      #     # OR for HTTP-only:
      #     # base_url: "https://dustlayer.io",
      #     # token: System.get_env("DUST_TOKEN")

      Reading.Link.changeset(%Reading.Link{}, %{slug: "x", title: "X", url: "http://x"})
      |> DustEcto.Repo.insert()
      # => {:ok, %Reading.Link{...}}
  """

  @version Mix.Project.config()[:version]

  @doc "Returns the package version string."
  def version, do: @version
end
