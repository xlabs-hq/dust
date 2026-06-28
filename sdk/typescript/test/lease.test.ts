import { describe, it, expect } from 'vitest'
import { AuthorizationError, Dust, LeaseError } from '../src/index'
import type { Lease } from '../src/index'

describe('Dust lease primitives', () => {
  function createDust(): Dust {
    return new Dust({ url: 'ws://localhost:7755/ws/sync', token: 'test' })
  }

  function stubPush(dust: any, reply: unknown | Error) {
    const pushed: Array<{ event: string; payload: Record<string, unknown> }> = []
    dust.joinedStores.set('s', Promise.resolve())
    dust.connection.push = async (_topic: string, event: string, payload: Record<string, unknown>) => {
      pushed.push({ event, payload })
      if (reply instanceof Error) throw reply
      return reply
    }
    return pushed
  }

  function pushError(response: unknown): Error {
    const err = new Error('push failed') as Error & { response?: unknown }
    err.response = response
    return err
  }

  it('lease acquire returns a Lease and sends ttl_ms/holder', async () => {
    const dust = createDust() as any
    const pushed = stubPush(dust, { store_seq: 1, token: 1, expires_at: 9_999, holder: 'n1' })

    const lease = await dust.lease('s', 'lock/a', { ttlMs: 60_000, holder: 'n1' })

    expect(lease).toEqual({ key: 'lock/a', token: 1, holder: 'n1', expiresAt: 9_999 })
    expect(pushed[0].payload).toMatchObject({ op: 'lease', path: 'lock/a', ttl_ms: 60_000, holder: 'n1' })
  })

  it('lease returns null when held by someone else', async () => {
    const dust = createDust() as any
    stubPush(dust, pushError({ reason: 'held' }))
    expect(await dust.lease('s', 'lock/a')).toBeNull()
  })

  it('lease throws LeaseError(occupied) on a non-lease value', async () => {
    const dust = createDust() as any
    stubPush(dust, pushError({ reason: 'occupied' }))

    await expect(dust.lease('s', 'lock/a')).rejects.toMatchObject({
      name: 'LeaseError',
      reason: 'occupied',
    })
  })

  it('lease throws LeaseError(unavailable) when the push has no server reason', async () => {
    const dust = createDust() as any
    stubPush(dust, new Error('Timeout waiting for reply'))

    await expect(dust.lease('s', 'lock/a')).rejects.toBeInstanceOf(LeaseError)
  })

  it('lease preserves AuthorizationError for a missing write scope', async () => {
    const dust = createDust() as any
    stubPush(dust, pushError({
      reason: 'missing_scope',
      scope: 'entries:write',
      message: 'Token is missing entries:write scope',
    }))

    await expect(dust.lease('s', 'lock/a')).rejects.toMatchObject({
      name: 'AuthorizationError',
      reason: 'missing_scope',
      scope: 'entries:write',
      message: 'Token is missing entries:write scope',
    })

    await expect(dust.lease('s', 'lock/a')).rejects.toBeInstanceOf(AuthorizationError)
  })

  it('renew keeps the token and returns the refreshed lease', async () => {
    const dust = createDust() as any
    const lease: Lease = { key: 'lock/a', token: 5, holder: 'n1', expiresAt: 1 }
    const pushed = stubPush(dust, { store_seq: 8, token: 5, expires_at: 20_000, holder: 'n1' })

    const renewed = await dust.renew('s', lease, { ttlMs: 120_000 })

    expect(renewed).toEqual({ key: 'lock/a', token: 5, holder: 'n1', expiresAt: 20_000 })
    expect(pushed[0].payload).toMatchObject({ op: 'renew', token: 5, ttl_ms: 120_000 })
  })

  it('renew returns null when the lease was lost', async () => {
    const dust = createDust() as any
    stubPush(dust, pushError({ reason: 'not_held' }))
    const lease: Lease = { key: 'lock/a', token: 5, holder: null, expiresAt: 1 }
    expect(await dust.renew('s', lease)).toBeNull()
  })

  it('release sends the token and resolves (idempotent no-op too)', async () => {
    const dust = createDust() as any
    const pushed = stubPush(dust, { released: false })
    const lease: Lease = { key: 'lock/a', token: 5, holder: null, expiresAt: 9_999 }

    await expect(dust.release('s', lease)).resolves.toBeUndefined()
    expect(pushed[0].payload).toMatchObject({ op: 'release', token: 5 })
  })

  it('put with fence sends the fence and maps a stale write to LeaseError(fenced)', async () => {
    const dust = createDust() as any
    const lease: Lease = { key: 'lock/a', token: 5, holder: null, expiresAt: 9_999 }

    const pushedOk = stubPush(dust, { store_seq: 10 })
    await dust.put('s', 'result/a', 'done', { fence: lease })
    expect(pushedOk[0].payload.fence).toEqual({ key: 'lock/a', token: 5 })

    stubPush(dust, pushError({ reason: 'fenced' }))
    await expect(dust.put('s', 'result/a', 'stale', { fence: lease })).rejects.toMatchObject({
      name: 'LeaseError',
      reason: 'fenced',
    })
  })
})
