import { describe, it, expect } from 'vitest'
import { encode, decode, WireMessage } from '../src/codec'

const testMsg: WireMessage = {
  joinRef: '1',
  ref: '2',
  topic: 'store:test/blog',
  event: 'event',
  payload: { store_seq: 42, op: 'set', path: 'users.alice', value: 'hello' },
}

describe('codec', () => {
  it('roundtrips JSON', () => {
    const encoded = encode(testMsg, 'json')
    expect(typeof encoded).toBe('string')
    const decoded = decode(encoded, 'json')
    expect(decoded).toEqual(testMsg)
  })

  it('roundtrips MessagePack', () => {
    const encoded = encode(testMsg, 'msgpack')
    expect(Buffer.isBuffer(encoded)).toBe(true)
    const decoded = decode(encoded as Buffer, 'msgpack')
    expect(decoded).toEqual(testMsg)
  })

  it('msgpack is smaller than JSON', () => {
    const json = encode(testMsg, 'json') as string
    const msgpack = encode(testMsg, 'msgpack') as Buffer
    expect(msgpack.length).toBeLessThan(json.length)
  })

  it('handles null joinRef and ref', () => {
    const msg: WireMessage = { joinRef: null, ref: null, topic: 'phoenix', event: 'heartbeat', payload: {} }
    const decoded = decode(encode(msg, 'json'), 'json')
    expect(decoded.joinRef).toBeNull()
    expect(decoded.ref).toBeNull()
  })
})
