/**
 * Segment-first paths for the Dust TypeScript SDK.
 *
 * A path is a non-empty array of non-empty string segments:
 *
 *     ["posts", "hello.world", "image/file"]
 *
 * Public SDK functions accept either a segment array or a canonical
 * rendered slash string (see `fromInput`). Internally the SDK uses
 * segment arrays; strings are rendered at boundaries (cache keys,
 * wire protocol, log lines).
 *
 * Mirrors `DustProtocol.Path` from the canonical wire-protocol
 * package.
 *
 * ## Rendering
 *
 * Canonical rendered paths join segments with `/` and escape per RFC
 * 6901 (JSON Pointer) inside each segment:
 *
 *     `~` -> `~0`
 *     `/` -> `~1`
 *
 * No other character has any special meaning. In particular, `.` is
 * literal — `"example.com"` is one segment, not two.
 */

export type Segments = string[]
export type PathInput = string | Segments

/**
 * Validate a segment array. Throws if it's empty, contains an
 * empty string, or contains non-string entries.
 */
export function fromSegments(segments: Segments): Segments {
  if (!Array.isArray(segments)) {
    throw new Error('segments must be an array of non-empty strings')
  }
  if (segments.length === 0) {
    throw new Error('path is empty')
  }
  for (const s of segments) {
    if (typeof s !== 'string') {
      throw new Error('segments must be an array of non-empty strings')
    }
    if (s === '') {
      throw new Error('segment is empty')
    }
  }
  return segments
}

/**
 * Render a segment array to canonical slash form, escaping `~` and
 * `/` inside each segment per RFC 6901.
 *
 * `~` must be escaped first or the `/` -> `~1` substitution would
 * create false `~1` sequences in subsequent decoding.
 */
export function render(segments: Segments): string {
  fromSegments(segments)
  return segments.map(escapeSegment).join('/')
}

function escapeSegment(seg: string): string {
  return seg.replace(/~/g, '~0').replace(/\//g, '~1')
}

/**
 * Parse a canonical rendered path into segments. Rejects empty paths,
 * empty segments (leading/trailing/double slash), and invalid `~`
 * escapes.
 */
export function parseRendered(s: string): Segments {
  if (typeof s !== 'string') {
    throw new Error('rendered path must be a string')
  }
  if (s === '') {
    throw new Error('path is empty')
  }
  const parts = s.split('/')
  if (parts.some((p) => p === '')) {
    throw new Error(`path "${s}" contains empty segments`)
  }
  return parts.map(unescapeSegment)
}

/**
 * Walks the segment once, treating `~` as the start of a two-char
 * escape. Anything else after `~` is rejected. Stricter than a
 * pair of replaces — actually rejects bad input rather than
 * silently leaving it.
 */
function unescapeSegment(seg: string): string {
  let out = ''
  let i = 0
  while (i < seg.length) {
    const ch = seg[i]
    if (ch === '~') {
      const next = seg[i + 1]
      if (next === '0') {
        out += '~'
        i += 2
      } else if (next === '1') {
        out += '/'
        i += 2
      } else {
        throw new Error(`invalid escape "~${next ?? ''}" in segment "${seg}"`)
      }
    } else {
      out += ch
      i += 1
    }
  }
  return out
}

/**
 * Round-trip a rendered path through parse + render. Useful at
 * trust boundaries to canonicalise input.
 */
export function normalizeRendered(s: string): string {
  return render(parseRendered(s))
}

/**
 * Accept either a rendered slash string or a segment array, return
 * validated segments. SDK entry points use this so callers can write
 * `dust.put(store, "a/b/c", val)` or `dust.put(store, ["a","b","c"], val)`
 * interchangeably.
 */
export function fromInput(input: PathInput): Segments {
  if (typeof input === 'string') {
    return parseRendered(input)
  }
  if (Array.isArray(input)) {
    return fromSegments(input)
  }
  throw new Error('path must be a string or array of strings')
}

/**
 * Append a single segment to a path. The new segment is taken
 * literally — no parsing, no special meaning for `.` or `/`.
 */
export function child(parent: Segments, segment: string): Segments {
  fromSegments(parent)
  if (typeof segment !== 'string' || segment === '') {
    throw new Error('child segment must be a non-empty string')
  }
  return [...parent, segment]
}

/**
 * Append multiple segments. Equivalent to repeated `child` but
 * cheaper for known-shape construction.
 */
export function concat(parent: Segments, tail: Segments): Segments {
  fromSegments(parent)
  fromSegments(tail)
  return [...parent, ...tail]
}

/** True if `ancestor` is a strict ancestor of `descendant`. */
export function isAncestor(ancestor: Segments, descendant: Segments): boolean {
  if (ancestor.length >= descendant.length) return false
  for (let i = 0; i < ancestor.length; i++) {
    if (ancestor[i] !== descendant[i]) return false
  }
  return true
}

/**
 * Rendered prefix string suitable for SQL/string prefix matches.
 * Always has a trailing `/` so it can't false-match a sibling
 * whose rendered form shares the parent's prefix bytes.
 */
export function renderDescendantPrefix(segments: Segments): string {
  return render(segments) + '/'
}

// ----------------------------------------------------------------------
// Legacy dotted-path helper (explicit opt-in). Callers that hold
// genuinely-legacy dotted strings call this *explicitly* to convert
// to a segment list, then pass the list to the public SDK API. Kept
// while the migration window is open; deleted once no callers
// remain.
// ----------------------------------------------------------------------

export function parseLegacyDotted(s: string): Segments {
  if (s === '') throw new Error('path is empty')
  const parts = s.split('.')
  if (parts.some((p) => p === '')) {
    throw new Error(`legacy path "${s}" contains empty segments`)
  }
  return parts
}

/**
 * Convert a caller-provided path into canonical slash-rendered form.
 * Accepts a segment array or a canonical slash-rendered string.
 *
 * Strings are interpreted as **canonical** — `"example.com"` is one
 * segment with a literal dot, not the legacy two-segment form. To
 * handle genuinely-legacy dotted input, callers must call
 * `parseLegacyDotted` explicitly first and pass the resulting array.
 */
export function normalizePath(path: PathInput): string {
  if (Array.isArray(path)) {
    return render(fromSegments(path))
  }
  if (typeof path !== 'string') {
    throw new Error('path must be a string or array of strings')
  }
  return normalizeRendered(path)
}

/**
 * Normalize a glob pattern to canonical slash-rendered form.
 * Wildcards `*` / `**` must already be expressed against slash
 * separators (`"posts/*"`, `"users/**"`). Legacy dotted patterns are
 * not accepted.
 */
export function normalizePattern(pattern: string): string {
  if (pattern === '**') return '**'
  if (typeof pattern !== 'string') {
    throw new Error('pattern must be a string')
  }
  const parts = pattern.split('/')
  if (parts.some((p) => p === '')) {
    throw new Error(`pattern "${pattern}" contains empty segments`)
  }
  return pattern
}
