# Crystal CLI Build & Release Design

## Goal

Set up GitHub Actions to build, test, and release the Dust Crystal CLI on every push and tagged release. Three target platforms, native runners only, static Linux binaries, dynamic macOS binaries.

## Scope

- **In scope:** CI on every push/PR, release automation on tagged versions, GitHub Releases as the distribution channel.
- **Out of scope:** Homebrew tap, curl install script, integration tests in CI, code coverage, nightly builds, Windows support.

## Workflows

Two workflows under `.github/workflows/`.

### `cli-ci.yml` — Per-commit gating

**Triggers:** `push` to `master` and `pull_request`, both filtered with `paths: cli/**` so unrelated commits don't fire it.

**Jobs:**

1. **lint** — `crystal tool format --check src/ spec/`. Fast, fails on style drift.
2. **test** — Unit tests on macOS arm64 + Linux x86_64. Skips integration tests (`integration_spec.cr`) since they need a running Dust server.
3. **build** — Full release build on all 3 target platforms in parallel. Acts as a "does it compile" gate.

### `cli-release.yml` — Tagged releases

**Trigger:** `push` of tags matching `cli-v*` (e.g., `cli-v0.1.0`).

**Why prefixed tags:** the monorepo will eventually have independent versioning for CLI, server, and SDK. Prefixing namespaces tags cleanly per component (`cli-v*`, `sdk-v*`, `server-v*`).

**Jobs:**

1. **build** — Matrix across 3 platforms in parallel, produces archived binaries.
2. **release** — `needs: build`. Creates GitHub Release with all artifacts attached, auto-generates notes from commits since previous `cli-v*` tag.

## Platform Builds

### macOS arm64

| | |
|---|---|
| Runner | `macos-14` |
| Crystal install | `crystal-lang/install-crystal` action |
| Build | `cd cli && shards install --production && crystal build src/dust.cr --release --no-debug -o dust` |
| Linking | Dynamic against libSystem + libsqlite3 (both ship with macOS) |
| Archive name | `dust-cli-{version}-aarch64-apple-darwin.tar.gz` |

### Linux x86_64

| | |
|---|---|
| Runner | `ubuntu-latest` |
| Build env | `crystallang/crystal:latest-alpine` Docker container |
| Setup | `apk add --no-cache sqlite-static sqlite-dev` |
| Build | `crystal build src/dust.cr --release --no-debug --static -o dust` |
| Linking | Fully static against musl libc |
| Archive name | `dust-cli-{version}-x86_64-unknown-linux-musl.tar.gz` |

### Linux arm64

Identical to Linux x86_64 except runner is `ubuntu-24.04-arm`. Archive: `dust-cli-{version}-aarch64-unknown-linux-musl.tar.gz`.

## Why containerized Linux but native macOS

- **macOS:** Cannot easily produce static binaries — no static libSystem. Native dynamic linking against system libraries is the platform standard, and macOS guarantees libsqlite3 + libSystem on every install.
- **Linux:** Distros vary wildly in libc and libsqlite versions. Static musl side-steps the compatibility matrix entirely. Every Crystal CLI distributed via GitHub Releases does this.

## Caching

- `shards install` cache keyed on `cli/shard.lock` hash.
- Crystal install action handles its own caching.

## Release Artifacts

Each tarball contains:

```
dust-cli-{version}-{target}/
├── dust          # Executable binary
├── LICENSE       # MIT license
└── README.md     # Top-level project README
```

### Checksums

`sha256sum` of each archive collected into a single `SHA256SUMS` file, attached to the release alongside the tarballs. Standard practice for binary distribution.

### Release creation

Uses `softprops/action-gh-release@v2`:
- Creates GitHub Release matching the tag
- Uploads all platform tarballs + `SHA256SUMS`
- Auto-generates release notes from commits since previous `cli-v*` tag
- Auto-publishes (not draft) — delete and re-tag if a release goes wrong

## Cutting a Release

```
# Update cli/shard.yml version field
git add cli/shard.yml
git commit -m "chore(cli): bump version to 0.1.0"
git tag cli-v0.1.0
git push origin master --tags
```

The release workflow runs, builds all 3 platforms, attaches artifacts, publishes the release.

## Repo Cleanup (Separate Commit)

The current repo has committed binaries that need to come out:

- Delete `cli/dust` (5.1MB ARM64 Mach-O binary)
- Delete `cli/dust.dwarf` (2.1MB debug symbols)
- Verify `cli/.gitignore` excludes `dust` and `*.dwarf`

Binaries don't belong in git — that's what releases are for.

## Deliberately Out of Scope

- **Integration tests in CI** — `integration_spec.cr` needs a running Phoenix server. Doable via service containers but 10x the workflow complexity. Unit tests (`config_spec`) cover what CI needs to gate.
- **`ameba` linting** — only `crystal tool format --check`. Adding ameba is a separate decision.
- **Code coverage** — premature, no baseline.
- **Nightly builds** — unnecessary for v0.1.
- **Homebrew tap** — scope C, deferred until there's user demand.
- **Curl install script** — same.
- **Universal macOS binary (Intel + ARM)** — Intel Macs are EOL, drop until someone asks.
- **Windows** — Crystal Windows support isn't production-ready.
