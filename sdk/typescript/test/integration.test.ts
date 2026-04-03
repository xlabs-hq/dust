/**
 * Integration tests for the Dust TypeScript SDK.
 *
 * Requires a running Dust server at ws://localhost:7755/ws/sync
 * and a valid store token.
 *
 * Run with: DUST_TOKEN=<token> DUST_STORE=<org/store> npm test -- test/integration.test.ts
 *
 * Skipped by default — enable by setting the DUST_TOKEN env var.
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest'
import { Dust } from '../src/dust'

const TOKEN = process.env.DUST_TOKEN
const STORE = process.env.DUST_STORE || 'test/integration'
const URL = process.env.DUST_URL || 'ws://localhost:7755/ws/sync'

const shouldRun = !!TOKEN

describe.skipIf(!shouldRun)('integration', () => {
  let dust: Dust

  beforeAll(() => {
    dust = new Dust({ url: URL, token: TOKEN!, format: 'json' })
  })

  afterAll(() => {
    dust.close()
  })

  it('puts and gets a value', async () => {
    const { storeSeq } = await dust.put(STORE, 'integration.test', 'hello')
    expect(storeSeq).toBeGreaterThan(0)

    // Wait a tick for the event to arrive and update cache
    await new Promise(r => setTimeout(r, 200))

    const value = await dust.get(STORE, 'integration.test')
    expect(value).toBe('hello')
  })

  it('subscribes and receives events', async () => {
    const events: unknown[] = []
    const unsub = dust.on(STORE, 'integration.**', (event) => {
      events.push(event)
    })

    await dust.put(STORE, 'integration.sub_test', 'world')

    // Wait for event
    await new Promise(r => setTimeout(r, 500))

    expect(events.length).toBeGreaterThanOrEqual(1)
    unsub()
  })

  it('increments a counter', async () => {
    await dust.increment(STORE, 'integration.counter', 5)
    await new Promise(r => setTimeout(r, 200))

    await dust.increment(STORE, 'integration.counter', 3)
    await new Promise(r => setTimeout(r, 200))

    const value = await dust.get(STORE, 'integration.counter')
    expect(value).toBe(8)
  })

  it('enums matching entries', async () => {
    await dust.put(STORE, 'integration.enum_a', 'a')
    await dust.put(STORE, 'integration.enum_b', 'b')
    await new Promise(r => setTimeout(r, 300))

    const entries = await dust.enum(STORE, 'integration.enum_*')
    expect(entries.length).toBe(2)
  })

  it('deletes an entry', async () => {
    await dust.put(STORE, 'integration.to_delete', 'bye')
    await new Promise(r => setTimeout(r, 200))

    await dust.delete(STORE, 'integration.to_delete')
    await new Promise(r => setTimeout(r, 200))

    const value = await dust.get(STORE, 'integration.to_delete')
    expect(value).toBeNull()
  })

  it('reports status', () => {
    const status = dust.status(STORE)
    expect(status.connected).toBe(true)
    expect(status.seq).toBeGreaterThan(0)
  })
})
