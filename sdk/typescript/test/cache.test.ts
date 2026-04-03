import { describe, it, expect } from 'vitest'
import { MemoryCache } from '../src/cache'

describe('MemoryCache', () => {
  it('stores and retrieves entries', () => {
    const cache = new MemoryCache()
    cache.set('s', 'a.b', { path: 'a.b', value: 'hello', type: 'string', seq: 1 })
    expect(cache.get('s', 'a.b')?.value).toBe('hello')
  })

  it('returns null for missing entries', () => {
    const cache = new MemoryCache()
    expect(cache.get('s', 'missing')).toBeNull()
  })

  it('deletes entries', () => {
    const cache = new MemoryCache()
    cache.set('s', 'a', { path: 'a', value: 1, type: 'integer', seq: 1 })
    cache.delete('s', 'a')
    expect(cache.get('s', 'a')).toBeNull()
  })

  it('deletes by prefix', () => {
    const cache = new MemoryCache()
    cache.set('s', 'users.alice', { path: 'users.alice', value: 'a', type: 'string', seq: 1 })
    cache.set('s', 'users.bob', { path: 'users.bob', value: 'b', type: 'string', seq: 2 })
    cache.set('s', 'config', { path: 'config', value: 'c', type: 'string', seq: 3 })
    cache.deletePrefix('s', 'users.')
    expect(cache.get('s', 'users.alice')).toBeNull()
    expect(cache.get('s', 'users.bob')).toBeNull()
    expect(cache.get('s', 'config')?.value).toBe('c')
  })

  it('queries entries by pattern', () => {
    const cache = new MemoryCache()
    cache.set('s', 'users.alice', { path: 'users.alice', value: 'a', type: 'string', seq: 1 })
    cache.set('s', 'users.bob', { path: 'users.bob', value: 'b', type: 'string', seq: 2 })
    cache.set('s', 'posts.hello', { path: 'posts.hello', value: 'h', type: 'string', seq: 3 })

    const results = cache.entries('s', 'users.*')
    expect(results.length).toBe(2)
    expect(results.map(e => e.path)).toEqual(['users.alice', 'users.bob'])
  })

  it('tracks lastSeq per store', () => {
    const cache = new MemoryCache()
    expect(cache.lastSeq('s')).toBe(0)
    cache.setLastSeq('s', 42)
    expect(cache.lastSeq('s')).toBe(42)
  })

  it('isolates stores', () => {
    const cache = new MemoryCache()
    cache.set('s1', 'key', { path: 'key', value: 'v1', type: 'string', seq: 1 })
    cache.set('s2', 'key', { path: 'key', value: 'v2', type: 'string', seq: 1 })
    expect(cache.get('s1', 'key')?.value).toBe('v1')
    expect(cache.get('s2', 'key')?.value).toBe('v2')
  })

  it('clears a store', () => {
    const cache = new MemoryCache()
    cache.set('s', 'a', { path: 'a', value: 1, type: 'integer', seq: 1 })
    cache.setLastSeq('s', 10)
    cache.clear('s')
    expect(cache.get('s', 'a')).toBeNull()
    expect(cache.lastSeq('s')).toBe(0)
  })
})
