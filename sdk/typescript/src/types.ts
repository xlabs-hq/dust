export interface DustOptions {
  url: string
  token: string
  deviceId?: string
  format?: 'msgpack' | 'json'
}

export interface Entry {
  path: string
  value: unknown
  type: string
  seq: number
}

export interface Page<T> {
  items: T[]
  nextCursor: string | null
}

export interface Event {
  storeSeq: number
  op: string
  path: string
  value: unknown
  deviceId: string
  clientOpId: string
}

export interface Status {
  connected: boolean
  seq: number
}

export type EventCallback = (event: Event) => void
