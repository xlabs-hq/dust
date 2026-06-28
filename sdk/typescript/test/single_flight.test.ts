import { describe, it, expect } from 'vitest'
import { AuthorizationError, Dust, SingleFlightAbort } from '../src/index'

describe('Dust.singleFlight', () => {
  function createDust(): any {
    return new Dust({ url: 'ws://localhost:7755/ws/sync', token: 'test' })
  }

  // Stub connection.push, dispatching per op. A handler may return a reply or
  // an Error to throw. Missing handlers throw (caught by best-effort paths).
  function stubByOp(dust: any, handlers: Record<string, (p: any) => unknown | Error>) {
    dust.joinedStores.set('s', Promise.resolve())
    const pushed: any[] = []
    dust.connection.push = async (_t: string, _e: string, payload: any) => {
      pushed.push(payload)
      const h = handlers[payload.op]
      if (!h) throw new Error(`no handler for op ${payload.op}`)
      const r = h(payload)
      if (r instanceof Error) throw r
      return r
    }
    return pushed
  }

  function pushError(response: unknown): Error {
    const err = new Error('push failed') as Error & { response?: unknown }
    err.response = response
    return err
  }

  it('fast path returns cached without coordinating', async () => {
    const dust = createDust()
    dust.joinedStores.set('s', Promise.resolve())
    dust.cache.set('s', 'k', {
      path: 'k',
      value: JSON.stringify({ r: 9 }),
      type: 'string',
      seq: 1,
      syncedAt: Date.now(),
    })

    const flight = await dust.singleFlight('s', 'k', () => ({ publish: { r: 0 } }))
    expect(flight).toEqual({ value: { r: 9 }, source: 'cached', stale: false, coordinated: true })
  })

  it('won: acquires, publishes fenced, releases, returns computed', async () => {
    const dust = createDust()
    const pushed = stubByOp(dust, {
      lease: () => ({ store_seq: 1, token: 1, expires_at: 9_999, holder: null }),
      set: () => ({ store_seq: 2 }),
      release: () => ({ store_seq: 3 }),
    })

    const flight = await dust.singleFlight('s', 'k', () => ({ publish: { r: 1 } }), {
      leaseTtl: 30_000,
    })

    expect(flight).toEqual({ value: { r: 1 }, source: 'computed', stale: false, coordinated: true })
    const set = pushed.find((p) => p.op === 'set')
    expect(set.value).toBe(JSON.stringify({ r: 1 }))
    expect(set.fence).toEqual({ key: '_dust:sf/k', token: 1 })
    expect(pushed.some((p) => p.op === 'release')).toBe(true)
  })

  it('abort releases and rejects with SingleFlightAbort', async () => {
    const dust = createDust()
    stubByOp(dust, {
      lease: () => ({ store_seq: 1, token: 1, expires_at: 9_999, holder: null }),
      release: () => ({ store_seq: 2 }),
    })

    await expect(
      dust.singleFlight('s', 'k', () => ({ abort: 'upstream_down' }), { leaseTtl: 30_000 }),
    ).rejects.toMatchObject({ name: 'SingleFlightAbort', reason: 'upstream_down' })
  })

  it('loser awaits and returns the winner-published value', async () => {
    const dust = createDust()
    stubByOp(dust, { lease: () => pushError({ reason: 'held' }) })

    const p = dust.singleFlight('s', 'k', () => ({ publish: { age: 0 } }), {
      fresh: (v: any) => v.age < 50,
      leaseTtl: 1_000,
    })

    // Let the loser subscribe + recheck, then deliver the winner's publish.
    await new Promise((r) => setTimeout(r, 10))
    dust.handleEvent('s', {
      store_seq: 5,
      op: 'set',
      path: 'k',
      value: JSON.stringify({ age: 0 }),
      device_id: 'other',
      client_op_id: 'remote',
    })

    const flight = await p
    expect(flight).toEqual({ value: { age: 0 }, source: 'awaited', stale: false, coordinated: true })
  })

  it('runLocal degrade runs uncoordinated when Dust is unavailable', async () => {
    const dust = createDust()
    // lease push throws without a server reason → mapped to unavailable.
    stubByOp(dust, { lease: () => new Error('Timeout waiting for reply') })

    const flight = await dust.singleFlight(
      's',
      'k',
      (lease: any) => {
        expect(lease).toBeNull()
        return { publish: { r: 7 } }
      },
      { onUnavailable: 'runLocal' },
    )

    expect(flight).toEqual({ value: { r: 7 }, source: 'computed', stale: false, coordinated: false })
  })

  it('does not run locally when lease is rejected for missing write scope', async () => {
    const dust = createDust()
    let ran = false
    stubByOp(dust, {
      lease: () => pushError({
        reason: 'missing_scope',
        scope: 'entries:write',
        message: 'Token is missing entries:write scope',
      }),
    })

    await expect(
      dust.singleFlight(
        's',
        'k',
        () => {
          ran = true
          return { publish: { r: 7 } }
        },
        { onUnavailable: 'runLocal' },
      ),
    ).rejects.toBeInstanceOf(AuthorizationError)

    expect(ran).toBe(false)
  })
})
