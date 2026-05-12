defmodule DustProtocol do
  @moduledoc "Shared wire protocol types for Dust server and SDKs."

  # Capability version history
  # 1: Initial protocol — JSON wire format, all current op types
  # 2: Adds optional `if_match` (CAS) on `set` writes with leaf values;
  #    introduces `conflict` reply
  # 3: Segment-first paths. Wire ops carry `path_segments`
  #    (authoritative) instead of dotted `path`. Slash-rendered strings
  #    use RFC 6901 escapes (`~0`, `~1`). Glob patterns are
  #    segment-aware; `**` is tail-only; `\*` / `\**` escape literal
  #    wildcard segments. No backwards compatibility with capver 2 for
  #    new writes — pre-launch break, see
  #    docs/plans/2026-05-12-segment-first-paths.md.
  @current_capver 3
  # Bumped together — clients on capver 2 must upgrade. Pre-launch we
  # don't owe backwards compatibility.
  @min_capver 3

  def current_capver, do: @current_capver
  def min_capver, do: @min_capver
end
