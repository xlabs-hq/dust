Application.put_env(:dustlayer, Dust.TestRepo,
  database: ":memory:",
  pool_size: 1
)

{:ok, _} = Dust.TestRepo.start_link()

# Run migration SQL directly (avoids needing schema_migrations table for in-memory DB)
Ecto.Adapters.SQL.query!(Dust.TestRepo, """
  CREATE TABLE IF NOT EXISTS dust_cache (
    store TEXT NOT NULL,
    path TEXT NOT NULL,
    value TEXT NOT NULL,
    type TEXT NOT NULL,
    seq INTEGER NOT NULL,
    synced_at INTEGER,
    UNIQUE(store, path)
  )
""")

ExUnit.start()
