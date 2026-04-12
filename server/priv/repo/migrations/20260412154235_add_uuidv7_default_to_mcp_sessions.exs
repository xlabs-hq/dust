defmodule Dust.Repo.Migrations.AddUuidv7DefaultToMcpSessions do
  use Ecto.Migration

  def change do
    execute(
      "ALTER TABLE mcp_sessions ALTER COLUMN id SET DEFAULT uuidv7()",
      "ALTER TABLE mcp_sessions ALTER COLUMN id DROP DEFAULT"
    )
  end
end
