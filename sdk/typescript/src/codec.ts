import { pack, unpack } from 'msgpackr'

export interface WireMessage {
  joinRef: string | null
  ref: string | null
  topic: string
  event: string
  payload: unknown
}

export type Format = 'msgpack' | 'json'

export function encode(msg: WireMessage, format: Format): Buffer | string {
  const arr = [msg.joinRef, msg.ref, msg.topic, msg.event, msg.payload]
  if (format === 'msgpack') {
    return Buffer.from(pack(arr))
  }
  return JSON.stringify(arr)
}

export function decode(data: Buffer | ArrayBuffer | string, format: Format): WireMessage {
  let arr: unknown[]
  if (format === 'msgpack') {
    const buf = data instanceof ArrayBuffer ? Buffer.from(data) : Buffer.from(data as Buffer)
    arr = unpack(buf) as unknown[]
  } else {
    arr = JSON.parse(typeof data === 'string' ? data : data.toString()) as unknown[]
  }
  return {
    joinRef: arr[0] as string | null,
    ref: arr[1] as string | null,
    topic: arr[2] as string,
    event: arr[3] as string,
    payload: arr[4],
  }
}
