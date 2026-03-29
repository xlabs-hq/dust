defmodule Dust.Repo.Migrations.EnableUuidv7 do
  use Ecto.Migration

  def up do
    # PostgreSQL 17+ has native uuidv7() support.
    # For older versions, install the pg_uuidv7 extension.
    # We check by attempting to call uuidv7() first.
    execute """
    DO $$
    BEGIN
      PERFORM uuidv7();
    EXCEPTION WHEN undefined_function THEN
      CREATE EXTENSION IF NOT EXISTS pg_uuidv7;
    END $$;
    """
  end

  def down do
    execute "DROP EXTENSION IF EXISTS pg_uuidv7"
  end
end
