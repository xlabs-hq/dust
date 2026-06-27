import { Connection } from './connection'
import { MemoryCache } from './cache'
import { match } from './glob'
import { normalizePath, normalizePattern, parseRendered, type PathInput } from './path'
import { ConflictError, ExistsError, LeaseError, SingleFlightAbort, SingleFlightTimeout } from './types'
import type {
  DustOptions,
  EnumOptions,
  Entry,
  Event,
  EventCallback,
  Flight,
  Lease,
  Page,
  PresentEvent,
  SfResult,
  Status,
} from './types'

const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms))

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
  //
  // Path arguments accept either a canonical slash-rendered string
  // (`"posts/hello"`) or a segment array (`["posts", "hello"]`). Both
  // are validated and normalised at the boundary; internally the
  // SDK always speaks canonical slash form.

  async get(store: string, path: PathInput): Promise<unknown> {
    const normalized = normalizePath(path)
    await this.ensureJoined(store)
    const entry = this.cache.get(store, normalized)
    return entry?.value ?? null
  }

  async entry(store: string, path: PathInput): Promise<Entry | null> {
    const normalized = normalizePath(path)
    await this.ensureJoined(store)
    return this.cache.readEntry(store, normalized)
  }

  async put(
    store: string,
    path: PathInput,
    value: unknown,
    opts?: { ifMatch?: number; ifAbsent?: boolean; fence?: Lease },
  ): Promise<{ storeSeq: number }> {
    return this.write(store, 'set', normalizePath(path), value, opts)
  }

  /**
   * Acquire (or steal an expired) lease at `key`. Returns the {@link Lease} on
   * acquisition, `null` if a live lease is held by someone else. Throws
   * {@link LeaseError} (`occupied` | `unavailable`) for the exceptional cases.
   */
  async lease(
    store: string,
    key: string,
    opts: { ttlMs?: number; holder?: string } = {},
  ): Promise<Lease | null> {
    const payload: Record<string, unknown> = { ttl_ms: opts.ttlMs ?? 30_000 }
    if (opts.holder !== undefined) payload.holder = opts.holder

    const reply = await this.leaseWrite(store, 'lease', normalizePath(key), payload)
    switch (reply.kind) {
      case 'ok':
        return leaseFromReply(normalizePath(key), reply.resp)
      case 'held':
      case 'not_held':
        return null
      default:
        throw new LeaseError(reply.reason)
    }
  }

  /** Extend a held lease (keeps its token). `null` if it was lost. */
  async renew(store: string, lease: Lease, opts: { ttlMs?: number } = {}): Promise<Lease | null> {
    const reply = await this.leaseWrite(store, 'renew', lease.key, {
      token: lease.token,
      ttl_ms: opts.ttlMs ?? 30_000,
    })

    switch (reply.kind) {
      case 'ok':
        return leaseFromReply(lease.key, reply.resp, lease.holder)
      case 'held':
      case 'not_held':
        return null
      default:
        throw new LeaseError(reply.reason)
    }
  }

  /** Release a held lease. Idempotent — a lost/stale token is a no-op. */
  async release(store: string, lease: Lease): Promise<void> {
    await this.leaseWrite(store, 'release', lease.key, { token: lease.token })
  }

  /**
   * Coordinated distributed cache-fill — compute `fn` once across the fleet and
   * share the result. At-least-once / single-flight while reachable, NOT
   * exactly-once; `fn` must be idempotent and publish a small pointer.
   *
   * `fn` receives the held lease (or `null` on the degraded `runLocal` path)
   * and returns `{ publish: value }` or `{ abort: reason }`. Resolves with a
   * {@link Flight}; rejects with {@link SingleFlightAbort} (fn aborted),
   * {@link SingleFlightTimeout}, or {@link LeaseError}.
   */
  async singleFlight<T = unknown>(
    store: string,
    key: string,
    fn: (lease: Lease | null) => SfResult<T> | Promise<SfResult<T>>,
    opts: {
      fresh?: (value: any) => boolean
      leaseTtl?: number
      waitTimeout?: number
      onUnavailable?: 'runLocal' | 'error'
      lockKey?: string
    } = {},
  ): Promise<Flight<T>> {
    const cfg = {
      fresh: opts.fresh,
      leaseTtl: opts.leaseTtl ?? 30_000,
      waitTimeout: opts.waitTimeout ?? (opts.leaseTtl ?? 30_000) + 5_000,
      onUnavailable: opts.onUnavailable ?? 'runLocal',
      lockKey: opts.lockKey ?? `_dust:sf/${key}`,
    }

    const cached = await this.lastValue(store, key)
    if (cached.hit && (!cfg.fresh || cfg.fresh(cached.value))) {
      return { value: cached.value as T, source: 'cached', stale: false, coordinated: true }
    }

    return this.sfCoordinate(store, key, fn, cfg, Date.now() + cfg.waitTimeout)
  }

  private async sfCoordinate<T>(store: string, key: string, fn: any, cfg: any, deadline: number): Promise<Flight<T>> {
    let lease: Lease | null
    try {
      lease = await this.lease(store, cfg.lockKey, { ttlMs: cfg.leaseTtl })
    } catch (err) {
      if (err instanceof LeaseError && err.reason === 'unavailable') {
        return this.sfDegraded(store, key, fn, cfg)
      }
      throw err
    }

    if (lease) return this.sfWon(store, key, fn, lease, cfg)

    const r = await this.sfAwait(store, key, cfg, deadline)
    if (r !== 'retry') return r as Flight<T>

    if (Date.now() < deadline) {
      await sleep(Math.floor(Math.random() * 250) + 1)
      return this.sfCoordinate(store, key, fn, cfg, deadline)
    }
    return this.sfOnTimeout(store, key, cfg)
  }

  private async sfWon<T>(store: string, key: string, fn: any, lease: Lease, cfg: any): Promise<Flight<T>> {
    const hb = this.startHeartbeat(store, lease, cfg.leaseTtl)
    let result: SfResult<T>
    try {
      result = await fn(lease)
    } finally {
      // Stop renewing. If fn threw, we do NOT release: the lease lingers to
      // lease_ttl and others re-elect (mirrors the Elixir recovery bound).
      clearInterval(hb)
    }

    if (result && 'publish' in result) {
      try {
        await this.put(store, key, JSON.stringify((result as { publish: T }).publish), { fence: lease })
      } catch (err) {
        if (err instanceof LeaseError && err.reason === 'fenced') throw err
        await this.release(store, lease).catch(() => {})
        throw err
      }
      await this.release(store, lease)
      const value = JSON.parse(JSON.stringify((result as { publish: T }).publish)) as T
      return { value, source: 'computed', stale: false, coordinated: true }
    }

    await this.release(store, lease)
    throw new SingleFlightAbort((result as { abort: unknown }).abort)
  }

  private async sfAwait<T>(store: string, key: string, cfg: any, deadline: number): Promise<Flight<T> | 'retry'> {
    let resolveFn!: (v: Flight<T> | 'retry') => void
    const promise = new Promise<Flight<T> | 'retry'>((res) => (resolveFn = res))

    let settled = false
    let timer: ReturnType<typeof setTimeout> | undefined
    const unsubs: Array<() => void> = []
    const finish = (v: Flight<T> | 'retry') => {
      if (settled) return
      settled = true
      unsubs.forEach((u) => u())
      if (timer) clearTimeout(timer)
      resolveFn(v)
    }

    const tryKey = async () => {
      const c = await this.lastValue(store, key)
      if (c.hit && (!cfg.fresh || cfg.fresh(c.value))) {
        finish({ value: c.value as T, source: 'awaited', stale: false, coordinated: true })
      }
    }

    // Subscribe BEFORE re-reading (lost-wakeup), to both the result key and the
    // lock key (a committed release → re-elect).
    unsubs.push(this.subscribeRaw(store, key, () => void tryKey()))
    unsubs.push(
      this.subscribeRaw(store, cfg.lockKey, (ev) => {
        if (ev.op === 'release') finish('retry')
      }),
    )

    await tryKey()
    if (!settled) {
      const wait = Math.min(cfg.leaseTtl, deadline - Date.now())
      if (wait <= 0) finish('retry')
      else timer = setTimeout(() => finish('retry'), wait)
    }

    return promise
  }

  private async sfDegraded<T>(store: string, key: string, fn: any, cfg: any): Promise<Flight<T>> {
    if (cfg.onUnavailable === 'error') throw new LeaseError('unavailable')

    const result: SfResult<T> = await fn(null)
    if (result && 'publish' in result) {
      // Fire-and-forget; never block/fail the local computation on Dust.
      void this.put(store, key, JSON.stringify((result as { publish: T }).publish)).catch(() => {})
      const value = JSON.parse(JSON.stringify((result as { publish: T }).publish)) as T
      return { value, source: 'computed', stale: false, coordinated: false }
    }
    throw new SingleFlightAbort((result as { abort: unknown }).abort)
  }

  private async sfOnTimeout<T>(store: string, key: string, cfg: any): Promise<Flight<T>> {
    const c = await this.lastValue(store, key)
    if (c.hit && cfg.fresh) {
      return { value: c.value as T, source: 'cached', stale: true, coordinated: true }
    }
    throw new SingleFlightTimeout()
  }

  private async lastValue(store: string, key: string): Promise<{ hit: boolean; value?: unknown }> {
    const entry = await this.entry(store, key)
    if (entry && entry.type !== 'lease' && typeof entry.value === 'string') {
      return { hit: true, value: JSON.parse(entry.value) }
    }
    return { hit: false }
  }

  private startHeartbeat(store: string, lease: Lease, ttl: number): ReturnType<typeof setInterval> {
    const interval = Math.max(Math.floor(ttl / 3), 1)
    return setInterval(() => {
      void this.renew(store, lease, { ttlMs: ttl }).catch(() => {})
    }, interval)
  }

  // Lightweight ongoing subscription (no bootstrap) used by singleFlight's
  // await. Returns an unsubscribe fn.
  private subscribeRaw(store: string, pattern: string, callback: WatchCallback): () => void {
    let subs = this.subscriptions.get(store)
    if (!subs) {
      subs = new Set()
      this.subscriptions.set(store, subs)
    }
    const sub: Subscription = { pattern: normalizePattern(pattern), callback, bootstrapPending: false }
    subs.add(sub)
    return () => subs!.delete(sub)
  }

  async merge(store: string, path: PathInput, value: Record<string, unknown>): Promise<{ storeSeq: number }> {
    return this.write(store, 'merge', normalizePath(path), value)
  }

  async delete(store: string, path: PathInput): Promise<{ storeSeq: number }> {
    return this.write(store, 'delete', normalizePath(path), null)
  }

  async increment(store: string, path: PathInput, delta: number = 1): Promise<{ storeSeq: number }> {
    return this.write(store, 'increment', normalizePath(path), delta)
  }

  async add(store: string, path: PathInput, member: unknown): Promise<{ storeSeq: number }> {
    return this.write(store, 'add', normalizePath(path), member)
  }

  async remove(store: string, path: PathInput, member: unknown): Promise<{ storeSeq: number }> {
    return this.write(store, 'remove', normalizePath(path), member)
  }

  on(store: string, pattern: string, callback: EventCallback): () => void {
    pattern = normalizePattern(pattern)
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
    pattern = normalizePattern(pattern)
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
    pattern = normalizePattern(pattern)
    await this.ensureJoined(store)
    if (opts === undefined) {
      return this.cache.entries(store, pattern)
    }
    return this.cache.browse(store, { ...opts, pattern })
  }

  async getMany(store: string, paths: PathInput[]): Promise<Record<string, unknown>> {
    if (paths.length > 1000) {
      throw new Error('getMany: maximum 1000 paths per call')
    }
    const normalized = paths.map(normalizePath)
    await this.ensureJoined(store)
    const raw = this.cache.readMany(store, normalized)
    const result: Record<string, unknown> = {}
    for (const [path, entry] of Object.entries(raw)) {
      result[path] = entry.value
    }
    return result
  }

  async range(
    store: string,
    from: PathInput,
    to: PathInput,
    opts: Omit<EnumOptions, 'select'> & { select?: 'entries' | 'keys' } = {},
  ): Promise<Page<Entry> | Page<string>> {
    if ((opts as { select?: string }).select === 'prefixes') {
      throw new Error('range: select prefixes is not supported')
    }
    const fromNorm = normalizePath(from)
    const toNorm = normalizePath(to)
    await this.ensureJoined(store)
    return this.cache.browse(store, { ...opts, from: fromNorm, to: toNorm })
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
    opts?: { ifMatch?: number; ifAbsent?: boolean; fence?: Lease },
  ): Promise<{ storeSeq: number }> {
    await this.ensureJoined(store)

    const topic = `store:${store}`
    const clientOpId = generateOpId()

    // capver 3 wire shape: send `path_segments` (authoritative)
    // alongside `path` (slash-rendered, back-compat). The server
    // prefers segments when present.
    const payload: Record<string, unknown> = {
      op,
      path,
      path_segments: parseRendered(path),
      client_op_id: clientOpId,
    }

    if (value !== null && value !== undefined) {
      payload.value = value
    }

    if (opts && typeof opts.ifMatch === 'number') {
      payload.if_match = opts.ifMatch
    }

    if (opts && opts.ifAbsent === true) {
      payload.if_absent = true
    }

    if (opts && opts.fence) {
      payload.fence = { key: opts.fence.key, token: opts.fence.token }
    }

    let response: { store_seq: number }
    try {
      response = (await this.connection.push(topic, 'write', payload)) as { store_seq: number }
    } catch (err) {
      // Detect the precondition error shapes from Connection.push: the thrown
      // Error has a `response` property mirroring the server's error reply.
      const resp = (err as { response?: unknown })?.response
      if (resp !== null && typeof resp === 'object') {
        const reason = (resp as { reason?: unknown }).reason
        const current = (resp as { current_revision?: unknown }).current_revision
        const currentRevision = typeof current === 'number' ? current : null

        if (reason === 'conflict') {
          throw new ConflictError(currentRevision)
        }

        if (reason === 'exists') {
          throw new ExistsError(currentRevision)
        }

        if (reason === 'fenced') {
          throw new LeaseError('fenced')
        }
      }
      throw err
    }
    return { storeSeq: response.store_seq }
  }

  // Push a lease op and classify the reply. Ordinary contention (held /
  // not_held) is a normal outcome, not an error; occupied/unavailable surface
  // as LeaseError to callers.
  private async leaseWrite(
    store: string,
    op: string,
    key: string,
    fields: Record<string, unknown>,
  ): Promise<
    | { kind: 'ok'; resp: Record<string, unknown> }
    | { kind: 'held' }
    | { kind: 'not_held' }
    | { kind: 'error'; reason: 'occupied' | 'unavailable' }
  > {
    await this.ensureJoined(store)
    const payload: Record<string, unknown> = {
      op,
      path: key,
      path_segments: parseRendered(key),
      client_op_id: generateOpId(),
      ...fields,
    }

    try {
      const resp = (await this.connection.push(`store:${store}`, 'write', payload)) as Record<
        string,
        unknown
      >
      return { kind: 'ok', resp }
    } catch (err) {
      const resp = (err as { response?: unknown })?.response
      const reason =
        resp !== null && typeof resp === 'object'
          ? (resp as { reason?: unknown }).reason
          : undefined

      if (reason === 'held') return { kind: 'held' }
      if (reason === 'not_held') return { kind: 'not_held' }
      if (reason === 'occupied') return { kind: 'error', reason: 'occupied' }
      // No server reason (timeout / disconnected) → treat as unavailable.
      return { kind: 'error', reason: 'unavailable' }
    }
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

    // Update cache based on op. `path + '/'` is the canonical
    // descendant-prefix form (slash-rendered, trailing slash so a
    // sibling like `posts/hello2` can't false-match `posts/hello`).
    if (op === 'delete' || op === 'release') {
      // `release` deletes the lease entry at the lock key.
      this.cache.delete(store, path)
      this.cache.deletePrefix(store, path + '/')
    } else {
      // `lease`/`renew` set the lease envelope; everything else sets its value.
      const type = inferType(value)
      this.cache.set(store, path, { path, value, type, seq: storeSeq })
    }

    // Advance lastSeq monotonically
    if (storeSeq > this.cache.lastSeq(store)) {
      this.cache.setLastSeq(store, storeSeq)
    }

    // Fire matching subscription callbacks. Both pattern and path
    // travel as slash-canonical strings; parse the path once into
    // segments and match.
    const event: Event = { storeSeq, op, path, value, deviceId, clientOpId }
    const subs = this.subscriptions.get(store)
    if (subs) {
      let pathSegments: string[]
      try {
        pathSegments = parseRendered(path)
      } catch {
        return
      }
      for (const sub of subs) {
        if (match(sub.pattern, pathSegments)) {
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

// Build a Lease from a server lease/renew reply (token + expires_at + holder).
function leaseFromReply(
  key: string,
  resp: Record<string, unknown>,
  fallbackHolder: string | null = null,
): Lease {
  return {
    key,
    token: resp.token as number,
    holder: (resp.holder as string | null | undefined) ?? fallbackHolder,
    expiresAt: resp.expires_at as number,
  }
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
