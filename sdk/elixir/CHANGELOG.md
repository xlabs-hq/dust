# Changelog

All notable changes to `dustlayer` are documented here. This project adheres to
[Semantic Versioning](https://semver.org).

## [Unreleased]

## 0.1.0 - 2026-06-27

Initial release.

- Reactive store client: connect to a Dust store, read and write data, and
  subscribe to changes with glob-pattern callbacks.
- Local cache with SQLite (`Dust.Cache.Ecto`) and in-memory (`Dust.Cache.Memory`)
  backends.
- Optional integrations: `phoenix_pubsub`, `ecto_sql`, `phoenix_live_view`, and
  `phoenix_live_dashboard`.
- `mix dust.gen.migration` generator for the local cache table.
- `[:dustlayer, :connection, :state_change]` telemetry.
