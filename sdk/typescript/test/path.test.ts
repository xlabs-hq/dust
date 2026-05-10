import { describe, it, expect } from 'vitest'
import { normalizePath, normalizePattern } from '../src/path'

describe('normalizePath', () => {
  it('passes dotted paths through unchanged', () => {
    expect(normalizePath('foo.bar.baz')).toBe('foo.bar.baz')
  })

  it('rewrites slashes to dots', () => {
    expect(normalizePath('foo/bar/baz')).toBe('foo.bar.baz')
  })

  it('handles a mix of separators', () => {
    expect(normalizePath('foo/bar.baz')).toBe('foo.bar.baz')
  })

  it('rejects empty paths', () => {
    expect(() => normalizePath('')).toThrow()
  })

  it('rejects empty segments', () => {
    expect(() => normalizePath('foo..bar')).toThrow(/empty segments/)
    expect(() => normalizePath('foo//bar')).toThrow(/empty segments/)
    expect(() => normalizePath('.foo')).toThrow(/empty segments/)
  })
})

describe('normalizePattern', () => {
  it('rewrites slashes to dots', () => {
    expect(normalizePattern('foo/bar/*')).toBe('foo.bar.*')
  })

  it('keeps glob wildcards intact', () => {
    expect(normalizePattern('**')).toBe('**')
    expect(normalizePattern('foo.*')).toBe('foo.*')
  })

  it('rejects empty segments', () => {
    expect(() => normalizePattern('foo//*')).toThrow(/empty segments/)
  })
})
