# Changelog

All notable changes to `dustlayer_ecto` are documented here. This project adheres
to [Semantic Versioning](https://semver.org).

## [Unreleased]

## 0.1.2 - 2026-06-27

## 0.1.1 - 2026-06-27

## 0.1.0 - 2026-06-27

Initial release.

- `DustEcto.Schema` + `DustEcto.Repo`: an Ecto-shaped facade over Dust for
  Phoenix apps.
- Two transports: `DustEcto.Transport.SDK` (Phoenix Channels via `dustlayer`,
  realtime) and `DustEcto.Transport.HTTP` (Req-based, stateless).
- Optional `DustEcto.Phoenix` PubSub bridge for broadcasting changes.
- Configured under the `:dustlayer_ecto` application namespace.
