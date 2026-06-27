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
  /**
   * Local wall-clock (unix epoch ms) when this mirror last wrote the row
   * from a sync event. `null` for entries that were never stamped (e.g.
   * subtree-assembled values).
   */
  syncedAt: number | null
}

export interface Page<T> {
  items: T[]
  nextCursor: string | null
}

export interface EnumOptions {
  limit?: number
  after?: string
  order?: 'asc' | 'desc'
  select?: 'entries' | 'keys' | 'prefixes'
}

export interface BrowseOptions {
  pattern?: string
  from?: string
  to?: string
  limit?: number
  after?: string
  order?: 'asc' | 'desc'
  select?: 'entries' | 'keys' | 'prefixes'
}

export interface Event {
  storeSeq: number
  op: string
  path: string
  value: unknown
  deviceId: string
  clientOpId: string
}

export interface PresentEvent {
  op: 'present'
  path: string
  value: unknown
  type: string
  seq: number
}

export interface Status {
  connected: boolean
  seq: number
}

export type EventCallback = (event: Event) => void

/**
 * Thrown by `Dust.put` when an `ifMatch` CAS precondition fails.
 *
 * `currentRevision` is the server's view of the current entry revision
 * (store_seq) at the time of the conflict, or `null` if the path doesn't
 * exist or the server didn't report it.
 */
export class ConflictError extends Error {
  readonly currentRevision: number | null

  constructor(currentRevision: number | null = null) {
    super('conflict')
    this.name = 'ConflictError'
    this.currentRevision = currentRevision
  }
}

/**
 * Thrown by `Dust.put` when an `ifAbsent` (put-new) precondition fails
 * because the key already exists.
 *
 * `currentRevision` is the server's view of the existing entry revision
 * at the time of the conflict, or `null` if not reported.
 */
export class ExistsError extends Error {
  readonly currentRevision: number | null

  constructor(currentRevision: number | null = null) {
    super('exists')
    this.name = 'ExistsError'
    this.currentRevision = currentRevision
  }
}

/**
 * A held lease — a point-in-time snapshot capability handle. Authority lives
 * on the server; `token` is the server-stamped monotonic fence token
 * (preserved across `renew`). Pass it to `renew`/`release` or a write's
 * `fence:` option.
 */
export interface Lease {
  key: string
  token: number
  holder: string | null
  expiresAt: number
}

/**
 * Thrown by lease operations and fenced writes for the exceptional cases:
 * `occupied` (a non-lease value sits at the key), `unavailable` (Dust
 * unreachable), or `fenced` (a write guarded by a lost lease). Ordinary
 * contention (`lease` held by someone else) is NOT an error — `lease`/`renew`
 * return `null` for that.
 */
export class LeaseError extends Error {
  readonly reason: 'occupied' | 'unavailable' | 'fenced'

  constructor(reason: 'occupied' | 'unavailable' | 'fenced') {
    super(reason)
    this.name = 'LeaseError'
    this.reason = reason
  }
}

/**
 * The result of `Dust.singleFlight`. `source`: `cached` (fresh local hit),
 * `computed` (this caller ran the fn), `awaited` (rode another filler's
 * result). `stale` is true only when a freshness-mode wait timed out and the
 * last value is returned. `coordinated` is false only on the degraded
 * `onUnavailable: 'runLocal'` path (possible duplicate work).
 */
export interface Flight<T = unknown> {
  value: T
  source: 'cached' | 'computed' | 'awaited'
  stale: boolean
  coordinated: boolean
}
