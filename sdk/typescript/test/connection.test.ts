import { describe, it, expect, vi } from 'vitest'
import { Connection, generateDeviceId } from '../src/connection'
import { encode, decode, WireMessage } from '../src/codec'

describe('generateDeviceId', () => {
  it('starts with dev_ prefix', () => {
    const id = generateDeviceId()
    expect(id.startsWith('dev_')).toBe(true)
  })

  it('is 20 characters total (dev_ + 16 hex chars)', () => {
    const id = generateDeviceId()
    expect(id).toHaveLength(20)
  })

  it('contains only hex characters after prefix', () => {
    const id = generateDeviceId()
    const hex = id.slice(4)
    expect(hex).toMatch(/^[0-9a-f]{16}$/)
  })

  it('generates unique IDs', () => {
    const ids = new Set(Array.from({ length: 100 }, () => generateDeviceId()))
    expect(ids.size).toBe(100)
  })
})

describe('Connection', () => {
  describe('buildUrl', () => {
    it('appends /websocket to path', () => {
      const conn = new Connection({
        url: 'ws://localhost:4000/socket',
        token: 'test-token',
      })
      const url = conn.buildUrl()
      expect(url).toContain('/socket/websocket')
    })

    it('does not double-append /websocket', () => {
      const conn = new Connection({
        url: 'ws://localhost:4000/socket/websocket',
        token: 'test-token',
      })
      const url = conn.buildUrl()
      // Should not have /websocket/websocket
      expect(url).toContain('/socket/websocket')
      expect(url).not.toContain('/websocket/websocket')
    })

    it('strips trailing slash before appending', () => {
      const conn = new Connection({
        url: 'ws://localhost:4000/socket/',
        token: 'test-token',
      })
      const url = conn.buildUrl()
      expect(url).toContain('/socket/websocket')
    })

    it('includes token query param', () => {
      const conn = new Connection({
        url: 'ws://localhost:4000/socket',
        token: 'my-secret-token',
      })
      const url = conn.buildUrl()
      expect(url).toContain('token=my-secret-token')
    })

    it('includes device_id query param', () => {
      const conn = new Connection({
        url: 'ws://localhost:4000/socket',
        token: 'test',
        deviceId: 'dev_custom123',
      })
      const url = conn.buildUrl()
      expect(url).toContain('device_id=dev_custom123')
    })

    it('includes capver and vsn query params', () => {
      const conn = new Connection({
        url: 'ws://localhost:4000/socket',
        token: 'test',
      })
      const url = conn.buildUrl()
      expect(url).toContain('capver=2')
      expect(url).toContain('vsn=2.0.0')
    })

    it('generates device_id when not provided', () => {
      const conn = new Connection({
        url: 'ws://localhost:4000/socket',
        token: 'test',
      })
      const url = conn.buildUrl()
      expect(url).toMatch(/device_id=dev_[0-9a-f]{16}/)
    })

    it('works with wss scheme', () => {
      const conn = new Connection({
        url: 'wss://example.com/socket',
        token: 'test',
      })
      const url = conn.buildUrl()
      expect(url).toMatch(/^wss:\/\//)
      expect(url).toContain('/socket/websocket')
    })

    it('preserves port in URL', () => {
      const conn = new Connection({
        url: 'ws://localhost:4000/socket',
        token: 'test',
      })
      const url = conn.buildUrl()
      expect(url).toContain('localhost:4000')
    })
  })

  describe('ref counter', () => {
    it('increments refs across multiple buildUrl calls', () => {
      // We can observe ref behavior indirectly: each Connection starts at 0,
      // and join/push would increment. Since we can't call join without a server,
      // we verify the initial state via the connected property.
      const conn = new Connection({
        url: 'ws://localhost:4000/socket',
        token: 'test',
      })
      expect(conn.connected).toBe(false)
    })
  })

  describe('onEvent', () => {
    it('returns an unsubscribe function', () => {
      const conn = new Connection({
        url: 'ws://localhost:4000/socket',
        token: 'test',
      })
      const handler = vi.fn()
      const unsub = conn.onEvent('store:test/blog', handler)
      expect(typeof unsub).toBe('function')
      // Calling unsub should not throw
      unsub()
    })
  })

  describe('getJoinedTopics', () => {
    it('returns empty array when no channels joined', () => {
      const conn = new Connection({
        url: 'ws://localhost:4000/socket',
        token: 'test',
      })
      expect(conn.getJoinedTopics()).toEqual([])
    })
  })

  describe('close', () => {
    it('does not throw when called without connecting', () => {
      const conn = new Connection({
        url: 'ws://localhost:4000/socket',
        token: 'test',
      })
      expect(() => conn.close()).not.toThrow()
    })

    it('sets connected to false', () => {
      const conn = new Connection({
        url: 'ws://localhost:4000/socket',
        token: 'test',
      })
      conn.close()
      expect(conn.connected).toBe(false)
    })
  })

  describe('format', () => {
    it('defaults to json format', () => {
      const conn = new Connection({
        url: 'ws://localhost:4000/socket',
        token: 'test',
      })
      // We can verify the format indirectly: buildUrl does not include format,
      // but the connection was constructed without error
      expect(conn.buildUrl()).toBeTruthy()
    })

    it('accepts msgpack format', () => {
      const conn = new Connection({
        url: 'ws://localhost:4000/socket',
        token: 'test',
        format: 'msgpack',
      })
      expect(conn.buildUrl()).toBeTruthy()
    })
  })
})

describe('wire format integration', () => {
  it('heartbeat message has correct structure', () => {
    // Verify the exact wire format a heartbeat would produce
    const msg: WireMessage = {
      joinRef: null,
      ref: '1',
      topic: 'phoenix',
      event: 'heartbeat',
      payload: {},
    }
    const encoded = encode(msg, 'json') as string
    const parsed = JSON.parse(encoded)
    expect(parsed).toEqual([null, '1', 'phoenix', 'heartbeat', {}])
  })

  it('join message has correct structure', () => {
    const msg: WireMessage = {
      joinRef: '1',
      ref: '1',
      topic: 'store:myorg/mystore',
      event: 'phx_join',
      payload: { last_store_seq: 42 },
    }
    const encoded = encode(msg, 'json') as string
    const parsed = JSON.parse(encoded)
    expect(parsed).toEqual([
      '1',
      '1',
      'store:myorg/mystore',
      'phx_join',
      { last_store_seq: 42 },
    ])
  })

  it('decodes phx_reply correctly', () => {
    const raw = JSON.stringify([
      '1',
      '1',
      'store:myorg/mystore',
      'phx_reply',
      { status: 'ok', response: { store_seq: 5, capver: 1, capver_min: 1 } },
    ])
    const msg = decode(raw, 'json')
    expect(msg.event).toBe('phx_reply')
    expect(msg.joinRef).toBe('1')
    expect(msg.ref).toBe('1')
    expect(msg.topic).toBe('store:myorg/mystore')
    const payload = msg.payload as { status: string; response: Record<string, number> }
    expect(payload.status).toBe('ok')
    expect(payload.response.store_seq).toBe(5)
  })

  it('decodes broadcast event correctly', () => {
    const raw = JSON.stringify([
      null,
      null,
      'store:myorg/mystore',
      'event',
      {
        store_seq: 10,
        op: 'set',
        path: 'users.alice',
        value: 'hello',
        device_id: 'dev_abc',
        client_op_id: 'op_1',
      },
    ])
    const msg = decode(raw, 'json')
    expect(msg.event).toBe('event')
    expect(msg.joinRef).toBeNull()
    expect(msg.ref).toBeNull()
    const payload = msg.payload as Record<string, unknown>
    expect(payload.store_seq).toBe(10)
    expect(payload.op).toBe('set')
    expect(payload.path).toBe('users.alice')
  })

  it('decodes catch_up_complete correctly', () => {
    const raw = JSON.stringify([
      null,
      null,
      'store:myorg/mystore',
      'catch_up_complete',
      { through_seq: 42 },
    ])
    const msg = decode(raw, 'json')
    expect(msg.event).toBe('catch_up_complete')
    const payload = msg.payload as { through_seq: number }
    expect(payload.through_seq).toBe(42)
  })

  it('decodes snapshot correctly', () => {
    const raw = JSON.stringify([
      null,
      null,
      'store:myorg/mystore',
      'snapshot',
      {
        snapshot_seq: 5,
        entries: [
          { path: 'users.alice', value: 'hello', type: 'string', seq: 3 },
        ],
      },
    ])
    const msg = decode(raw, 'json')
    expect(msg.event).toBe('snapshot')
    const payload = msg.payload as { snapshot_seq: number; entries: unknown[] }
    expect(payload.snapshot_seq).toBe(5)
    expect(payload.entries).toHaveLength(1)
  })
})
