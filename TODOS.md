# Dust TODOs

Generated from CEO Plan Review on 2026-04-01.

## P1 — Production Blockers

### Deployment Config
- **What:** Dockerfile, fly.toml or docker-compose.yml, production config (secrets, pool sizing)
- **Why:** Server has zero deployment config. Can't ship without it.
- **Effort:** S (CC: ~30 min)
- **Depends on:** Nothing

### Admin Panel Authentication
- **What:** AdminWeb.Endpoint has zero auth. Add Plug.BasicAuth or restrict to localhost.
- **Why:** Anyone reaching the admin port gets full access to all data.
- **Effort:** S (CC: ~20 min)
- **Depends on:** Nothing

## P2 — Code Quality

### @spec Type Annotations
- **What:** Add Dialyzer specs to Writer, Sync, Conflict, StoreChannel, Rollback.
- **Why:** Protocol-critical system with 7 value types and 6 operations benefits from compile-time checks.
- **Effort:** S (CC: ~20 min)
- **Depends on:** Nothing

## Deferred Scope

### Edge Reads via Regional Cache
- **What:** Put read replicas at the edge for sub-10ms global reads.
- **Why:** Premature without users needing multi-region. Architecture supports future addition.
- **Effort:** L
- **Revisit when:** Multi-region demand exists
