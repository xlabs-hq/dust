ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Dust.Repo, :manual)

# Clean SQLite store files once before the suite. Per-test cleanup is unsafe
# because async tests would race: one test's setup would rm_rf files another
# test was mid-write on, producing `disk I/O error` failures. UUIDv7 primary
# keys ensure no path collisions between tests within a run, so a single
# suite-start wipe is sufficient.
_ =
  :dust
  |> Application.get_env(:store_data_dir, "priv/stores")
  |> File.rm_rf!()
