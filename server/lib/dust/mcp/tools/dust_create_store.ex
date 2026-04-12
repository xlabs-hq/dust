defmodule Dust.MCP.Tools.DustCreateStore do
  @moduledoc "MCP tool: create a new store under an organization."

  use GenMCP.Suite.Tool,
    name: "dust_create_store",
    description: "Create a new Dust store under an organization the caller belongs to.",
    input_schema: %{
      type: :object,
      properties: %{
        org: %{type: :string, description: "Organization slug"},
        name: %{type: :string, description: "New store name"}
      },
      required: [:org, :name]
    }

  alias Dust.Accounts
  alias Dust.Accounts.Organization
  alias Dust.MCP.Principal
  alias Dust.Repo
  alias Dust.Stores
  alias GenMCP.MCP

  @impl true
  def call(req, channel, _arg) do
    %{"org" => org_slug, "name" => name} = req.params.arguments

    with {:ok, org} <- find_org(org_slug),
         :ok <- check_membership(channel.assigns.mcp_principal, org),
         {:ok, store} <- Stores.create_store(org, %{name: name}) do
      payload = %{store: "#{org.slug}/#{store.name}", id: store.id}
      {:result, MCP.call_tool_result(text: Jason.encode!(payload)), channel}
    else
      {:error, reason} -> {:error, to_string_reason(reason), channel}
      {:error, _tag, _meta} = err -> {:error, to_string_reason(err), channel}
    end
  end

  defp find_org(slug) do
    case Repo.get_by(Organization, slug: slug) do
      nil -> {:error, "Organization not found: #{slug}"}
      org -> {:ok, org}
    end
  end

  defp check_membership(%Principal{kind: :user_session, user: user}, org) do
    if Accounts.user_belongs_to_org?(user, org.id) do
      :ok
    else
      {:error, "Not a member of #{org.slug}"}
    end
  end

  defp check_membership(%Principal{kind: :store_token}, _org) do
    {:error, "Store tokens cannot create new stores"}
  end

  defp to_string_reason(%Ecto.Changeset{} = cs), do: inspect(cs.errors)
  defp to_string_reason(reason) when is_binary(reason), do: reason
  defp to_string_reason(reason), do: inspect(reason)
end
