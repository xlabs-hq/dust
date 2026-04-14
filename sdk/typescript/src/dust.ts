import { Connection } from './connection'
import { MemoryCache } from './cache'
import { match } from './glob'
import { ConflictError } from './types'
import type { DustOptions, EnumOptions, Entry, Event, EventCallback, Page, PresentEvent, Status } from './types'

type WatchCallback = (event: Event | PresentEvent) => void

interface Subscription {
  pattern: string
  callback: WatchCallback
  bootstrapPending?: boolean
  pendingEvents?: Event[]
}

export class Dust {
  private connection: Connection
  private cache: MemoryCache
  private subscriptions = new Map<string, Set<Subscription>>()
  private joinedStores = new Map<string, Promise<void>>()
  private catchUpComplete = new Map<string, boolean>()

  constructor(opts: DustOptions) {
    this.connection = new Connection(opts)
    this.cache = new MemoryCache()

    // On reconnect, clear join state so stores get re-joined
    this.connection.onReconnect(() => {
      this.rejoinAllStores()
    })
  }

  // -- Public API --

  async get(store: string, path: string): Promise<unknown> {
    await this.ensureJoined(store)
    const entry = this.cache.get(store, path)
    return entry?.value ?? null
  }

  async entry(store: string, path: string): Promise<Entry | null> {
    await this.ensureJoined(store)
    return this.cache.readEntry(store, path)
  }

  async put(
    store: string,
    path: string,
    value: unknown,
    opts?: { ifMatch?: number },
  ): Promise<{ storeSeq: number }> {
    return this.write(store, 'set', path, value, opts)
  }

  async merge(store: string, path: string, value: Record<string, unknown>): Promise<{ storeSeq: number }> {
    return this.write(store, 'merge', path, value)
  }

  async delete(store: string, path: string): Promise<{ storeSeq: number }> {
    return this.write(store, 'delete', path, null)
  }

  async increment(store: string, path: string, delta: number = 1): Promise<{ storeSeq: number }> {
    return this.write(store, 'increment', path, delta)
  }

  async add(store: string, path: string, member: unknown): Promise<{ storeSeq: number }> {
    return this.write(store, 'add', path, member)
  }

  async remove(store: string, path: string, member: unknown): Promise<{ storeSeq: number }> {
    return this.write(store, 'remove', path, member)
  }

  on(store: string, pattern: string, callback: EventCallback): () => void {
    let subs = this.subscriptions.get(store)
    if (!subs) {
      subs = new Set()
      this.subscriptions.set(store, subs)
    }
    const sub: Subscription = { pattern, callback: callback as WatchCallback }
    subs.add(sub)

    // Ensure joined — catch errors to prevent unhandled rejections
    this.ensureJoined(store).catch(() => {
      // Join failed — will be retried on next operation or reconnect
    })

    // Return unsubscribe function
    return () => { subs!.delete(sub) }
  }

  /**
   * Subscribe to changes matching a pattern, with all currently-cached
   * matching entries delivered as `present` events before any live events.
   *
   * Returns a Promise that resolves to an unsubscribe function once the
   * initial bootstrap has completed. Bootstrap entries are emitted
   * synchronously after the cache is hydrated, so no live event can
   * interleave mid-loop.
   *
   * **Race-window semantics:** If a live event for a matching path arrives
   * during the hydration window (between `await ensureJoined` and the
   * bootstrap loop), the cache is updated first, then the event is buffered.
   * The bootstrap loop will emit the (freshly-written) entry as a `present`
   * event, then the drain loop will emit the original live event — so the
   * same path may appear twice, once as `present` and once as the original
   * op. Present-before-live ordering is always preserved for any given path.
   * Write consumers to apply deltas idempotently so double-delivery is safe.
   *
   * @param store - Store name (e.g. "org/store")
   * @param pattern - Glob pattern (`*`, `**`, literal segments)
   * @param callback - Function called with each event. Receives
   *   `PresentEvent` for bootstrap items and `Event` for live updates.
   * @param opts - Options for bootstrap: `limit` (default 50, max 1000),
   *   `order` ('asc' | 'desc', default 'asc').
   * @returns Promise resolving to an unsubscribe function.
   */
  async watch(
    store: string,
    pattern: string,
    callback: WatchCallback,
    opts: { limit?: number; order?: 'asc' | 'desc' } = {},
  ): Promise<() => void> {
    const limit = Math.min(opts.limit ?? 50, 1000)
    const order = opts.order ?? 'asc'

    const sub: Subscription = {
      pattern,
      callback,
      bootstrapPending: true,
      pendingEvents: [],
    }

    let storeSubs = this.subscriptions.get(store)
    if (!storeSubs) {
      storeSubs = new Set()
      this.subscriptions.set(store, storeSubs)
    }
    storeSubs.add(sub)
    const unsubscribe = () => { storeSubs!.delete(sub) }

    try {
      await this.ensureJoined(store)

      const page = this.cache.browse(store, {
        pattern,
        limit,
        order,
        select: 'entries',
      }) as Page<Entry>

      // Synchronous dispatch — no await in this loop.
      // JS single-thread guarantee prevents interleaving with handleEvent.
      for (const entry of page.items) {
        callback({
          op: 'present',
          path: entry.path,
          value: entry.value,
          type: entry.type,
          seq: entry.seq,
        })
      }

      // Drain events queued during the ensureJoined gap
      for (const event of sub.pendingEvents!) {
        callback(event)
      }
      sub.pendingEvents = []
      sub.bootstrapPending = false
    } catch (err) {
      unsubscribe()
      throw err
    }

    return unsubscribe
  }

  async enum(store: string, pattern: string): Promise<Entry[]>
  async enum(
    store: string,
    pattern: string,
    opts: EnumOptions & { select: 'keys' | 'prefixes' },
  ): Promise<Page<string>>
  async enum(
    store: string,
    pattern: string,
    opts: EnumOptions & { select?: 'entries' },
  ): Promise<Page<Entry>>
  async enum(
    store: string,
    pattern: string,
    opts?: EnumOptions,
  ): Promise<Entry[] | Page<Entry> | Page<string>> {
    await this.ensureJoined(store)
    if (opts === undefined) {
      return this.cache.entries(store, pattern)
    }
    return this.cache.browse(store, { ...opts, pattern })
  }

  async getMany(store: string, paths: string[]): Promise<Record<string, unknown>> {
    if (paths.length > 1000) {
      throw new Error('getMany: maximum 1000 paths per call')
    }
    await this.ensureJoined(store)
    const raw = this.cache.readMany(store, paths)
    const result: Record<string, unknown> = {}
    for (const [path, entry] of Object.entries(raw)) {
      result[path] = entry.value
    }
    return result
  }

  async range(
    store: string,
    from: string,
    to: string,
    opts: Omit<EnumOptions, 'select'> & { select?: 'entries' | 'keys' } = {},
  ): Promise<Page<Entry> | Page<string>> {
    if ((opts as { select?: string }).select === 'prefixes') {
      throw new Error('range: select prefixes is not supported')
    }
    await this.ensureJoined(store)
    return this.cache.browse(store, { ...opts, from, to })
  }

  status(store: string): Status {
    return {
      connected: this.connection.connected,
      seq: this.cache.lastSeq(store),
    }
  }

  close(): void {
    this.connection.close()
    this.joinedStores.clear()
    this.catchUpComplete.clear()
  }

  // -- Internal --

  private async write(
    store: string,
    op: string,
    path: string,
    value: unknown,
    opts?: { ifMatch?: number },
  ): Promise<{ storeSeq: number }> {
    await this.ensureJoined(store)

    const topic = `store:${store}`
    const clientOpId = generateOpId()

    const payload: Record<string, unknown> = {
      op,
      path,
      client_op_id: clientOpId,
    }

    if (value !== null && value !== undefined) {
      payload.value = value
    }

    if (opts && typeof opts.ifMatch === 'number') {
      payload.if_match = opts.ifMatch
    }

    let response: { store_seq: number }
    try {
      response = (await this.connection.push(topic, 'write', payload)) as { store_seq: number }
    } catch (err) {
      // Detect the conflict error shape from Connection.push: the thrown Error
      // has a `response` property mirroring the server's error reply.
      const resp = (err as { response?: unknown })?.response
      if (
        resp !== null &&
        typeof resp === 'object' &&
        (resp as { reason?: unknown }).reason === 'conflict'
      ) {
        const current = (resp as { current_revision?: unknown }).current_revision
        const currentRevision = typeof current === 'number' ? current : null
        throw new ConflictError(currentRevision)
      }
      throw err
    }
    return { storeSeq: response.store_seq }
  }

  private ensureJoined(store: string): Promise<void> {
    const existing = this.joinedStores.get(store)
    if (existing) return existing

    const promise = this.doJoin(store).catch((err) => {
      // Clear the failed promise so the next call retries
      this.joinedStores.delete(store)
      throw err
    })
    this.joinedStores.set(store, promise)
    return promise
  }

  private async doJoin(store: string): Promise<void> {
    const topic = `store:${store}`
    const lastSeq = this.cache.lastSeq(store)

    // Register event handler BEFORE joining to catch catch-up events
    // (idempotent — Connection deduplicates handlers per topic)
    this.registerEventHandler(store)

    this.catchUpComplete.delete(store)
    await this.connection.join(store, lastSeq)

    // Wait for catch-up to complete (with timeout)
    await this.waitForCatchUp(store)
  }

  private registeredHandlers = new Set<string>()

  private registerEventHandler(store: string): void {
    const topic = `store:${store}`
    if (this.registeredHandlers.has(topic)) return
    this.registeredHandlers.add(topic)
    this.connection.onEvent(topic, (event: string, payload: unknown) => {
      this.handleChannelEvent(store, event, payload)
    })
  }

  private rejoinAllStores(): void {
    // Collect stores that were previously joined
    const stores = Array.from(this.joinedStores.keys())
    // Clear all join state
    this.joinedStores.clear()
    this.catchUpComplete.clear()
    // Re-join each store (event handlers are already registered)
    for (const store of stores) {
      this.ensureJoined(store).catch(() => {
        // Will retry on next operation
      })
    }
  }

  private waitForCatchUp(store: string): Promise<void> {
    if (this.catchUpComplete.get(store)) return Promise.resolve()

    return new Promise((resolve) => {
      const checkInterval = setInterval(() => {
        if (this.catchUpComplete.get(store)) {
          clearInterval(checkInterval)
          resolve()
        }
      }, 10)

      // Timeout after 10 seconds — resolve anyway, catch-up may still be in progress
      setTimeout(() => {
        clearInterval(checkInterval)
        resolve()
      }, 10_000)
    })
  }

  private handleChannelEvent(store: string, event: string, payload: unknown): void {
    switch (event) {
      case 'event':
        this.handleEvent(store, payload as Record<string, unknown>)
        break
      case 'snapshot':
        this.handleSnapshot(store, payload as Record<string, unknown>)
        break
      case 'catch_up_complete':
        this.handleCatchUpComplete(store, payload as Record<string, unknown>)
        break
    }
  }

  private handleEvent(store: string, raw: Record<string, unknown>): void {
    const storeSeq = raw.store_seq as number
    const op = raw.op as string
    const path = raw.path as string
    const value = raw.value
    const deviceId = raw.device_id as string
    const clientOpId = raw.client_op_id as string

    // Update cache based on op
    if (op === 'delete') {
      this.cache.delete(store, path)
      this.cache.deletePrefix(store, path + '.')
    } else {
      const type = inferType(value)
      this.cache.set(store, path, { path, value, type, seq: storeSeq })
    }

    // Advance lastSeq monotonically
    if (storeSeq > this.cache.lastSeq(store)) {
      this.cache.setLastSeq(store, storeSeq)
    }

    // Fire matching subscription callbacks
    const event: Event = { storeSeq, op, path, value, deviceId, clientOpId }
    const subs = this.subscriptions.get(store)
    if (subs) {
      for (const sub of subs) {
        if (match(sub.pattern, path)) {
          if (sub.bootstrapPending) {
            sub.pendingEvents!.push(event)
          } else {
            sub.callback(event)
          }
        }
      }
    }
  }

  private handleSnapshot(store: string, raw: Record<string, unknown>): void {
    const snapshotSeq = raw.snapshot_seq as number
    const entries = raw.entries as Record<string, { value: unknown; type: string }>

    // Clear and repopulate cache
    this.cache.clear(store)
    for (const [path, entry] of Object.entries(entries)) {
      this.cache.set(store, path, {
        path,
        value: entry.value,
        type: entry.type,
        seq: snapshotSeq,
      })
    }
    this.cache.setLastSeq(store, snapshotSeq)
  }

  private handleCatchUpComplete(store: string, raw: Record<string, unknown>): void {
    const throughSeq = raw.through_seq as number
    if (throughSeq > this.cache.lastSeq(store)) {
      this.cache.setLastSeq(store, throughSeq)
    }
    this.catchUpComplete.set(store, true)
  }
}

export function generateOpId(): string {
  return Array.from(
    { length: 16 },
    () => Math.floor(Math.random() * 16).toString(16),
  ).join('')
}

export function inferType(value: unknown): string {
  if (value === null || value === undefined) return 'null'
  if (typeof value === 'boolean') return 'boolean'
  if (typeof value === 'number') return Number.isInteger(value) ? 'integer' : 'float'
  if (typeof value === 'string') return 'string'
  if (Array.isArray(value)) return 'list'
  if (typeof value === 'object') return 'map'
  return 'unknown'
}
