import { describe, it, expect } from 'vitest'
import { Dust, inferType } from '../src/dust'

// We test the Dust class's event handling logic by accessing private methods
// via `as any`. The Connection requires a real server, so we skip integration
// tests here and focus on the core state management.

describe('Dust', () => {
  function createDust(): Dust {
    return new Dust({ url: 'ws://localhost:7755/ws/sync', token: 'test' })
  }

  describe('event handling', () => {
    it('handleEvent updates cache on set', () => {
      const dust = createDust() as any
      dust.handleEvent('test/store', {
        store_seq: 1, op: 'set', path: 'users.alice', value: 'hello',
        device_id: 'dev_1', client_op_id: 'op_1',
      })
      expect(dust.cache.get('test/store', 'users.alice')?.value).toBe('hello')
      expect(dust.cache.lastSeq('test/store')).toBe(1)
    })

    it('handleEvent removes entry on delete', () => {
      const dust = createDust() as any
      dust.handleEvent('test/store', {
        store_seq: 1, op: 'set', path: 'a', value: 'v',
        device_id: 'd', client_op_id: 'o1',
      })
      dust.handleEvent('test/store', {
        store_seq: 2, op: 'delete', path: 'a', value: null,
        device_id: 'd', client_op_id: 'o2',
      })
      expect(dust.cache.get('test/store', 'a')).toBeNull()
    })

    it('handleEvent deletes descendants on delete', () => {
      const dust = createDust() as any
      dust.handleEvent('test/store', {
        store_seq: 1, op: 'set', path: 'users.alice.name', value: 'Alice',
        device_id: 'd', client_op_id: 'o1',
      })
      dust.handleEvent('test/store', {
        store_seq: 2, op: 'set', path: 'users.alice.email', value: 'a@b.com',
        device_id: 'd', client_op_id: 'o2',
      })
      dust.handleEvent('test/store', {
        store_seq: 3, op: 'delete', path: 'users.alice', value: null,
        device_id: 'd', client_op_id: 'o3',
      })
      expect(dust.cache.get('test/store', 'users.alice.name')).toBeNull()
      expect(dust.cache.get('test/store', 'users.alice.email')).toBeNull()
    })

    it('advances lastSeq monotonically', () => {
      const dust = createDust() as any
      dust.handleEvent('test/store', {
        store_seq: 5, op: 'set', path: 'a', value: 1,
        device_id: 'd', client_op_id: 'o1',
      })
      dust.handleEvent('test/store', {
        store_seq: 3, op: 'set', path: 'b', value: 2,
        device_id: 'd', client_op_id: 'o2',
      })
      expect(dust.cache.lastSeq('test/store')).toBe(5)
    })
  })

  describe('snapshot handling', () => {
    it('replaces cache on snapshot', () => {
      const dust = createDust() as any
      // Pre-populate cache
      dust.handleEvent('test/store', {
        store_seq: 1, op: 'set', path: 'old', value: 'v',
        device_id: 'd', client_op_id: 'o1',
      })

      dust.handleSnapshot('test/store', {
        snapshot_seq: 10,
        entries: {
          'new.key': { value: 'fresh', type: 'string' },
        },
      })

      expect(dust.cache.get('test/store', 'old')).toBeNull()
      expect(dust.cache.get('test/store', 'new.key')?.value).toBe('fresh')
      expect(dust.cache.lastSeq('test/store')).toBe(10)
    })
  })

  describe('catch_up_complete', () => {
    it('marks store as caught up and advances lastSeq', () => {
      const dust = createDust() as any
      dust.handleCatchUpComplete('test/store', { through_seq: 42 })
      expect(dust.catchUpComplete.get('test/store')).toBe(true)
      expect(dust.cache.lastSeq('test/store')).toBe(42)
    })

    it('does not regress lastSeq', () => {
      const dust = createDust() as any
      dust.handleEvent('test/store', {
        store_seq: 50, op: 'set', path: 'a', value: 1,
        device_id: 'd', client_op_id: 'o1',
      })
      dust.handleCatchUpComplete('test/store', { through_seq: 42 })
      expect(dust.cache.lastSeq('test/store')).toBe(50)
    })
  })

  describe('handleChannelEvent routing', () => {
    it('routes event to handleEvent', () => {
      const dust = createDust() as any
      dust.handleChannelEvent('test/store', 'event', {
        store_seq: 1, op: 'set', path: 'x', value: 'y',
        device_id: 'd', client_op_id: 'o1',
      })
      expect(dust.cache.get('test/store', 'x')?.value).toBe('y')
    })

    it('routes snapshot to handleSnapshot', () => {
      const dust = createDust() as any
      dust.handleChannelEvent('test/store', 'snapshot', {
        snapshot_seq: 5,
        entries: { 'k': { value: 'v', type: 'string' } },
      })
      expect(dust.cache.get('test/store', 'k')?.value).toBe('v')
    })

    it('routes catch_up_complete to handleCatchUpComplete', () => {
      const dust = createDust() as any
      dust.handleChannelEvent('test/store', 'catch_up_complete', { through_seq: 10 })
      expect(dust.catchUpComplete.get('test/store')).toBe(true)
    })

    it('ignores unknown event types', () => {
      const dust = createDust() as any
      // Should not throw
      dust.handleChannelEvent('test/store', 'unknown_event', { foo: 'bar' })
      expect(dust.cache.lastSeq('test/store')).toBe(0)
    })
  })

  describe('subscriptions', () => {
    it('fires callback for matching events', () => {
      const dust = createDust() as any
      const events: any[] = []
      dust.subscriptions.set('test/store', new Set([
        { pattern: 'users.*', callback: (e: any) => events.push(e) },
      ]))

      dust.handleEvent('test/store', {
        store_seq: 1, op: 'set', path: 'users.alice', value: 'hello',
        device_id: 'd', client_op_id: 'o1',
      })

      expect(events.length).toBe(1)
      expect(events[0].path).toBe('users.alice')
      expect(events[0].storeSeq).toBe(1)
      expect(events[0].op).toBe('set')
      expect(events[0].value).toBe('hello')
    })

    it('does not fire callback for non-matching events', () => {
      const dust = createDust() as any
      const events: any[] = []
      dust.subscriptions.set('test/store', new Set([
        { pattern: 'users.*', callback: (e: any) => events.push(e) },
      ]))

      dust.handleEvent('test/store', {
        store_seq: 1, op: 'set', path: 'posts.hello', value: 'v',
        device_id: 'd', client_op_id: 'o1',
      })

      expect(events.length).toBe(0)
    })

    it('fires multiple matching callbacks', () => {
      const dust = createDust() as any
      const events1: any[] = []
      const events2: any[] = []
      dust.subscriptions.set('test/store', new Set([
        { pattern: 'users.*', callback: (e: any) => events1.push(e) },
        { pattern: '**', callback: (e: any) => events2.push(e) },
      ]))

      dust.handleEvent('test/store', {
        store_seq: 1, op: 'set', path: 'users.alice', value: 'v',
        device_id: 'd', client_op_id: 'o1',
      })

      expect(events1.length).toBe(1)
      expect(events2.length).toBe(1)
    })

    it('unsubscribe removes callback', () => {
      const dust = createDust()
      const events: any[] = []
      const unsub = dust.on('test/store', 'users.*', (e) => events.push(e))
      unsub()

      ;(dust as any).handleEvent('test/store', {
        store_seq: 1, op: 'set', path: 'users.alice', value: 'v',
        device_id: 'd', client_op_id: 'o1',
      })

      expect(events.length).toBe(0)
    })

    it('isolates subscriptions between stores', () => {
      const dust = createDust() as any
      const events: any[] = []
      dust.subscriptions.set('store_a', new Set([
        { pattern: '**', callback: (e: any) => events.push(e) },
      ]))

      dust.handleEvent('store_b', {
        store_seq: 1, op: 'set', path: 'x', value: 'v',
        device_id: 'd', client_op_id: 'o1',
      })

      expect(events.length).toBe(0)
    })
  })

  describe('entry', () => {
    it('returns the cached Entry for a present path', async () => {
      const dust = createDust() as any
      // Mark store as joined so entry() skips the real join.
      dust.joinedStores.set('test/store', Promise.resolve())
      dust.cache.set('test/store', 'users.alice.name', {
        path: 'users.alice.name',
        value: 'Alice',
        type: 'string',
        seq: 7,
      })

      const result = await dust.entry('test/store', 'users.alice.name')

      expect(result).toEqual({
        path: 'users.alice.name',
        value: 'Alice',
        type: 'string',
        seq: 7,
      })
    })

    it('returns null for a missing path', async () => {
      const dust = createDust() as any
      dust.joinedStores.set('test/store', Promise.resolve())

      const result = await dust.entry('test/store', 'no.such')

      expect(result).toBeNull()
    })
  })

  describe('status', () => {
    it('returns seq from cache', () => {
      const dust = createDust() as any
      dust.cache.setLastSeq('test/store', 42)
      const s = dust.status('test/store')
      expect(s.seq).toBe(42)
    })

    it('returns 0 seq for unknown store', () => {
      const dust = createDust()
      const s = dust.status('unknown')
      expect(s.seq).toBe(0)
    })
  })

  describe('close', () => {
    it('clears joinedStores and catchUpComplete', () => {
      const dust = createDust() as any
      dust.joinedStores.set('s', Promise.resolve())
      dust.catchUpComplete.set('s', true)

      dust.close()

      expect(dust.joinedStores.size).toBe(0)
      expect(dust.catchUpComplete.size).toBe(0)
    })
  })

  describe('reconnect lifecycle', () => {
    it('rejoinAllStores clears join state and re-joins', () => {
      const dust = createDust() as any
      // Simulate a store that was previously joined
      dust.joinedStores.set('test/store', Promise.resolve())
      dust.catchUpComplete.set('test/store', true)
      dust.registeredHandlers.add('store:test/store')

      // Track join attempts via ensureJoined
      let joinAttempts = 0
      const originalDoJoin = dust.doJoin.bind(dust)
      dust.doJoin = async (store: string) => {
        joinAttempts++
        // Don't actually connect — just track the call
        dust.catchUpComplete.set(store, true)
      }

      dust.rejoinAllStores()

      // joinedStores should have a new promise (not the old resolved one)
      expect(dust.joinedStores.has('test/store')).toBe(true)
      expect(joinAttempts).toBe(1)
    })

    it('ensureJoined clears failed promise on rejection', async () => {
      const dust = createDust() as any
      let callCount = 0

      dust.doJoin = async () => {
        callCount++
        if (callCount === 1) throw new Error('connection refused')
        dust.catchUpComplete.set('test/store', true)
      }

      // First attempt fails
      await expect(dust.ensureJoined('test/store')).rejects.toThrow('connection refused')

      // joinedStores should be cleared
      expect(dust.joinedStores.has('test/store')).toBe(false)

      // Second attempt should retry (not return cached failure)
      await dust.ensureJoined('test/store')
      expect(callCount).toBe(2)
    })

    it('on() does not throw unhandled rejection on join failure', () => {
      const dust = createDust() as any
      dust.doJoin = async () => { throw new Error('unavailable') }

      // This should NOT throw — the error is caught internally
      expect(() => {
        dust.on('test/store', '**', () => {})
      }).not.toThrow()
    })
  })
})

describe('inferType', () => {
  it('detects null', () => {
    expect(inferType(null)).toBe('null')
    expect(inferType(undefined)).toBe('null')
  })

  it('detects boolean', () => {
    expect(inferType(true)).toBe('boolean')
    expect(inferType(false)).toBe('boolean')
  })

  it('detects integer', () => {
    expect(inferType(42)).toBe('integer')
    expect(inferType(0)).toBe('integer')
    expect(inferType(-7)).toBe('integer')
  })

  it('detects float', () => {
    expect(inferType(3.14)).toBe('float')
    expect(inferType(-0.5)).toBe('float')
  })

  it('detects string', () => {
    expect(inferType('hello')).toBe('string')
    expect(inferType('')).toBe('string')
  })

  it('detects list', () => {
    expect(inferType([1, 2, 3])).toBe('list')
    expect(inferType([])).toBe('list')
  })

  it('detects map', () => {
    expect(inferType({ a: 1 })).toBe('map')
    expect(inferType({})).toBe('map')
  })
})
