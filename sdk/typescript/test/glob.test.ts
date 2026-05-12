import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { compile, match } from '../src/glob'

describe('compile', () => {
  it('compiles a segment array', () => {
    expect(compile(['posts', '*'])).toMatchObject({ tokens: expect.any(Array) })
  })

  it('compiles a rendered slash string', () => {
    expect(compile('posts/*')).toMatchObject({ tokens: expect.any(Array) })
  })

  it('rejects empty pattern', () => {
    expect(() => compile([])).toThrow()
    expect(() => compile('')).toThrow()
  })

  it('rejects ** in non-tail position', () => {
    expect(() => compile(['a', '**', 'b'])).toThrow(/tail position/)
    expect(() => compile('a/**/b')).toThrow(/tail position/)
  })

  it('accepts ** in tail position', () => {
    expect(() => compile(['a', '**'])).not.toThrow()
    expect(() => compile('a/**')).not.toThrow()
  })
})

describe('match — wildcards', () => {
  it('* matches exactly one segment', () => {
    expect(match(['posts', '*'], ['posts', 'hello'])).toBe(true)
    expect(match(['posts', '*'], ['posts'])).toBe(false)
    expect(match(['posts', '*'], ['posts', 'hello', 'title'])).toBe(false)
  })

  it('tail ** matches one-or-more segments', () => {
    expect(match(['posts', '**'], ['posts', 'a'])).toBe(true)
    expect(match(['posts', '**'], ['posts', 'a', 'b', 'c'])).toBe(true)
    expect(match(['posts', '**'], ['posts'])).toBe(false)
  })

  it('literal segments match exactly', () => {
    expect(match(['a', 'b', 'c'], ['a', 'b', 'c'])).toBe(true)
    expect(match(['a', 'b', 'c'], ['a', 'b', 'd'])).toBe(false)
  })

  it('* mid-pattern', () => {
    expect(match(['a', '*', 'c'], ['a', 'b', 'c'])).toBe(true)
    expect(match(['a', '*', 'c'], ['a', 'b', 'd'])).toBe(false)
  })
})

describe('match — literal characters', () => {
  it('dots are literal', () => {
    expect(match(['hello.world'], ['hello.world'])).toBe(true)
    expect(match(['hello.world'], ['hello', 'world'])).toBe(false)
  })

  it('rendered string with escapes round-trips', () => {
    expect(match('files/image~1file', ['files', 'image/file'])).toBe(true)
    expect(match('a~0b', ['a~b'])).toBe(true)
  })
})

describe('match — literal-wildcard escapes', () => {
  it('\\* matches literal asterisk segment', () => {
    expect(match(['a', '\\*'], ['a', '*'])).toBe(true)
    expect(match(['a', '\\*'], ['a', 'x'])).toBe(false)
  })

  it('\\** matches literal double-asterisk segment', () => {
    expect(match(['a', '\\**'], ['a', '**'])).toBe(true)
    expect(match(['a', '\\**'], ['a', 'x', 'y'])).toBe(false)
  })
})

// ----------------------------------------------------------------------
// Fixture-driven conformance against the canonical protocol package.
// ----------------------------------------------------------------------

interface MatchVector {
  valid: true
  pattern_segments: string[]
  pattern_rendered: string
  path: string[]
  match: boolean
  note?: string
}

interface InvalidPatternVector {
  valid: false
  pattern_rendered: string
  error: string
}

type GlobVector = MatchVector | InvalidPatternVector

const fixturePath = resolve(__dirname, '../../../protocol/spec/fixtures/glob_vectors.json')
const vectors: GlobVector[] = JSON.parse(readFileSync(fixturePath, 'utf-8'))

describe('fixture conformance (protocol/spec/fixtures/glob_vectors.json)', () => {
  for (const [idx, v] of vectors.entries()) {
    if (v.valid) {
      it(`#${idx}: ${JSON.stringify(v.pattern_segments)} vs ${JSON.stringify(v.path)} → ${v.match}`, () => {
        // Both pattern forms must give the same result.
        expect(match(v.pattern_segments, v.path)).toBe(v.match)
        expect(match(v.pattern_rendered, v.path)).toBe(v.match)
      })
    } else {
      it(`#${idx}: pattern ${JSON.stringify(v.pattern_rendered)} rejected (${v.error})`, () => {
        expect(() => compile(v.pattern_rendered)).toThrow()
      })
    }
  }
})
