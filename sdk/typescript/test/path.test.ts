import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import {
  fromSegments,
  parseRendered,
  render,
  normalizeRendered,
  fromInput,
  child,
  concat,
  isAncestor,
  renderDescendantPrefix,
  normalizePath,
  normalizePattern,
  parseLegacyDotted,
} from '../src/path'

describe('fromSegments', () => {
  it('accepts a non-empty array of non-empty strings', () => {
    expect(fromSegments(['a', 'b'])).toEqual(['a', 'b'])
  })

  it('preserves dots inside segments', () => {
    expect(fromSegments(['hello.world'])).toEqual(['hello.world'])
  })

  it('rejects empty array', () => {
    expect(() => fromSegments([])).toThrow(/empty/)
  })

  it('rejects empty segment', () => {
    expect(() => fromSegments(['a', '', 'b'])).toThrow(/empty/)
  })
})

describe('render', () => {
  it('joins segments with slashes', () => {
    expect(render(['a', 'b', 'c'])).toBe('a/b/c')
  })

  it('leaves dots literal', () => {
    expect(render(['hello.world'])).toBe('hello.world')
  })

  it('escapes literal slash as ~1', () => {
    expect(render(['files', 'image/file'])).toBe('files/image~1file')
  })

  it('escapes literal tilde as ~0', () => {
    expect(render(['a~b'])).toBe('a~0b')
  })

  it('encodes tilde before slash (correct escape order)', () => {
    expect(render(['a/b~c'])).toBe('a~1b~0c')
  })
})

describe('parseRendered', () => {
  it('splits on slash, dots stay literal', () => {
    expect(parseRendered('a/b/c')).toEqual(['a', 'b', 'c'])
    expect(parseRendered('hello.world')).toEqual(['hello.world'])
  })

  it('decodes ~1 → / and ~0 → ~', () => {
    expect(parseRendered('files/image~1file')).toEqual(['files', 'image/file'])
    expect(parseRendered('a~0b')).toEqual(['a~b'])
  })

  it('rejects empty string', () => {
    expect(() => parseRendered('')).toThrow(/empty/)
  })

  it('rejects leading / trailing / double slash', () => {
    expect(() => parseRendered('/a')).toThrow(/empty segments/)
    expect(() => parseRendered('a/')).toThrow(/empty segments/)
    expect(() => parseRendered('a//b')).toThrow(/empty segments/)
  })

  it('rejects bare or invalid ~ escapes', () => {
    expect(() => parseRendered('a~')).toThrow(/invalid escape/)
    expect(() => parseRendered('a~b')).toThrow(/invalid escape/)
    expect(() => parseRendered('a~2b')).toThrow(/invalid escape/)
  })
})

describe('round trip', () => {
  const cases: Array<string[]> = [
    ['a', 'b', 'c'],
    ['hello.world'],
    ['files', 'image/file'],
    ['a~b', 'c/d'],
    ['~~~~'],
    ['//'],
  ]

  for (const segments of cases) {
    it(`renders and re-parses ${JSON.stringify(segments)}`, () => {
      const rendered = render(segments)
      expect(parseRendered(rendered)).toEqual(segments)
    })
  }

  const renderedCases = ['a/b/c', 'hello.world', 'files/image~1file', 'a~0b/c~1d', '~0~0', '~1~1']
  for (const rendered of renderedCases) {
    it(`parses and re-renders ${JSON.stringify(rendered)}`, () => {
      const segments = parseRendered(rendered)
      expect(render(segments)).toBe(rendered)
    })
  }
})

describe('normalizeRendered', () => {
  it('returns canonical form of a valid rendered path', () => {
    expect(normalizeRendered('a/b/c')).toBe('a/b/c')
  })

  it('propagates parse errors', () => {
    expect(() => normalizeRendered('a//b')).toThrow(/empty/)
    expect(() => normalizeRendered('a~')).toThrow(/invalid escape/)
  })
})

describe('fromInput', () => {
  it('accepts a rendered string', () => {
    expect(fromInput('a/b/c')).toEqual(['a', 'b', 'c'])
  })

  it('accepts a segment array', () => {
    expect(fromInput(['a', 'b'])).toEqual(['a', 'b'])
  })

  it('rejects neither-string-nor-array input', () => {
    // @ts-expect-error - testing runtime rejection
    expect(() => fromInput(42)).toThrow()
  })
})

describe('child / concat', () => {
  it('child appends literally', () => {
    expect(child(['posts'], 'image/file')).toEqual(['posts', 'image/file'])
  })

  it('concat appends a segment array', () => {
    expect(concat(['a'], ['b', 'c'])).toEqual(['a', 'b', 'c'])
  })

  it('child rejects empty new segment', () => {
    expect(() => child(['posts'], '')).toThrow()
  })
})

describe('isAncestor', () => {
  it('parent is ancestor of child', () => {
    expect(isAncestor(['a'], ['a', 'b'])).toBe(true)
  })

  it('path is not its own ancestor', () => {
    expect(isAncestor(['a'], ['a'])).toBe(false)
  })

  it('byte-prefix that crosses segment boundary is NOT ancestor', () => {
    // Segment-aware: ["post"] is not an ancestor of ["posts", "x"]
    // even though "post" is a byte prefix of "posts".
    expect(isAncestor(['post'], ['posts', 'x'])).toBe(false)
  })
})

describe('renderDescendantPrefix', () => {
  it('trailing slash for SQL-LIKE prefix matches', () => {
    expect(renderDescendantPrefix(['posts', 'hello.world'])).toBe('posts/hello.world/')
  })

  it('escapes slashes in segments so the trailing / cannot false-match', () => {
    expect(renderDescendantPrefix(['files', 'a/b'])).toBe('files/a~1b/')
  })
})

describe('legacy compatibility helpers', () => {
  it('parseLegacyDotted splits on dots', () => {
    expect(parseLegacyDotted('a.b.c')).toEqual(['a', 'b', 'c'])
  })

  it('normalizePath: legacy dotted → canonical slash', () => {
    expect(normalizePath('a.b.c')).toBe('a/b/c')
  })

  it('normalizePath: canonical slash → unchanged', () => {
    expect(normalizePath('a/b/c')).toBe('a/b/c')
  })

  it('normalizePath: segment array → canonical slash', () => {
    expect(normalizePath(['a', 'b', 'c'])).toBe('a/b/c')
  })

  it('normalizePattern: legacy dotted with wildcard → canonical slash', () => {
    expect(normalizePattern('foo.*')).toBe('foo/*')
  })

  it('normalizePattern: ** passes through', () => {
    expect(normalizePattern('**')).toBe('**')
  })
})

// ----------------------------------------------------------------------
// Fixture-driven conformance against the canonical protocol package.
// Same JSON file is consumed by every SDK port; any divergence fails
// these tests.
// ----------------------------------------------------------------------

interface ValidVector {
  valid: true
  segments: string[]
  rendered: string
  note?: string
}

interface InvalidVector {
  valid: false
  rendered: string
  error: string
}

type PathVector = ValidVector | InvalidVector

const fixturePath = resolve(__dirname, '../../../protocol/spec/fixtures/path_vectors.json')
const vectors: PathVector[] = JSON.parse(readFileSync(fixturePath, 'utf-8'))

describe('fixture conformance (protocol/spec/fixtures/path_vectors.json)', () => {
  for (const [idx, v] of vectors.entries()) {
    if (v.valid) {
      it(`#${idx}: ${JSON.stringify(v.segments)} ↔ ${JSON.stringify(v.rendered)}`, () => {
        expect(render(v.segments)).toBe(v.rendered)
        expect(parseRendered(v.rendered)).toEqual(v.segments)
      })
    } else {
      it(`#${idx}: ${JSON.stringify(v.rendered)} rejected (${v.error})`, () => {
        expect(() => parseRendered(v.rendered)).toThrow()
      })
    }
  }
})
