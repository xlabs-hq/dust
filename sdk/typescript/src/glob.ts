/**
 * Segment-aware glob matching against `path.ts` segment arrays.
 *
 * Mirrors `DustProtocol.Glob` from the canonical wire-protocol
 * package.
 *
 * ## Pattern grammar
 *
 * A pattern is a non-empty array of pattern segments. Each segment is
 * either:
 *
 *   - `"*"` — matches exactly one path segment
 *   - `"**"` — matches one or more path segments; **only valid in the
 *     tail position**
 *   - `"\*"` — matches a path segment that is literally `"*"`
 *   - `"\**"` — matches a path segment that is literally `"**"`
 *   - any other string — matches that exact path segment
 *
 * Patterns can also be given as rendered slash strings, decoded with
 * the same JSON Pointer escape rules as `path.ts`.
 */

import { fromSegments, parseRendered, type Segments, type PathInput } from './path'

type Token = { kind: 'literal'; value: string } | { kind: 'one' } | { kind: 'many' }

export interface Compiled {
  readonly tokens: ReadonlyArray<Token>
}

export function compile(input: PathInput): Compiled {
  const segments =
    typeof input === 'string' ? parseRendered(input) : fromSegments(input as Segments)

  const tokens: Token[] = segments.map(classifySegment)

  // Validate `**` is tail-only.
  for (let i = 0; i < tokens.length; i++) {
    if (tokens[i].kind === 'many' && i !== tokens.length - 1) {
      throw new Error('** is only valid in the tail position of a glob pattern')
    }
  }

  return { tokens }
}

function classifySegment(seg: string): Token {
  if (seg === '*') return { kind: 'one' }
  if (seg === '**') return { kind: 'many' }
  if (seg === '\\*') return { kind: 'literal', value: '*' }
  if (seg === '\\**') return { kind: 'literal', value: '**' }
  return { kind: 'literal', value: seg }
}

/**
 * Test whether a (compiled or raw) pattern matches a segment-array
 * path. If `pattern` is a string or array, it is compiled on the
 * fly; compile errors propagate.
 */
export function match(pattern: Compiled | PathInput, path: Segments): boolean {
  const compiled = isCompiled(pattern) ? pattern : compile(pattern)
  return walk(compiled.tokens, 0, path, 0)
}

function isCompiled(v: unknown): v is Compiled {
  return typeof v === 'object' && v !== null && Array.isArray((v as Compiled).tokens)
}

function walk(tokens: ReadonlyArray<Token>, ti: number, path: Segments, pi: number): boolean {
  // Both exhausted = match
  if (ti === tokens.length && pi === path.length) return true

  // Tail `**`: match if path has at least one remaining segment.
  if (ti === tokens.length - 1 && tokens[ti].kind === 'many') {
    return pi < path.length
  }

  if (ti === tokens.length || pi === path.length) return false

  const t = tokens[ti]
  if (t.kind === 'one') {
    return walk(tokens, ti + 1, path, pi + 1)
  }
  if (t.kind === 'literal') {
    return t.value === path[pi] && walk(tokens, ti + 1, path, pi + 1)
  }
  // many but not in tail position — caught at compile time but be
  // defensive in case a hand-constructed Compiled bypasses validation.
  return false
}
