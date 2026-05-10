interface DustOptions {
    url: string;
    token: string;
    deviceId?: string;
    format?: 'msgpack' | 'json';
}
interface Entry {
    path: string;
    value: unknown;
    type: string;
    seq: number;
}
interface Page<T> {
    items: T[];
    nextCursor: string | null;
}
interface EnumOptions {
    limit?: number;
    after?: string;
    order?: 'asc' | 'desc';
    select?: 'entries' | 'keys' | 'prefixes';
}
interface BrowseOptions {
    pattern?: string;
    from?: string;
    to?: string;
    limit?: number;
    after?: string;
    order?: 'asc' | 'desc';
    select?: 'entries' | 'keys' | 'prefixes';
}
interface Event {
    storeSeq: number;
    op: string;
    path: string;
    value: unknown;
    deviceId: string;
    clientOpId: string;
}
interface PresentEvent {
    op: 'present';
    path: string;
    value: unknown;
    type: string;
    seq: number;
}
interface Status {
    connected: boolean;
    seq: number;
}
type EventCallback = (event: Event) => void;
/**
 * Thrown by `Dust.put` when an `ifMatch` CAS precondition fails.
 *
 * `currentRevision` is the server's view of the current entry revision
 * (store_seq) at the time of the conflict, or `null` if the path doesn't
 * exist or the server didn't report it.
 */
declare class ConflictError extends Error {
    readonly currentRevision: number | null;
    constructor(currentRevision?: number | null);
}

type WatchCallback = (event: Event | PresentEvent) => void;
declare class Dust {
    private connection;
    private cache;
    private subscriptions;
    private joinedStores;
    private catchUpComplete;
    constructor(opts: DustOptions);
    get(store: string, path: string): Promise<unknown>;
    entry(store: string, path: string): Promise<Entry | null>;
    put(store: string, path: string, value: unknown, opts?: {
        ifMatch?: number;
    }): Promise<{
        storeSeq: number;
    }>;
    merge(store: string, path: string, value: Record<string, unknown>): Promise<{
        storeSeq: number;
    }>;
    delete(store: string, path: string): Promise<{
        storeSeq: number;
    }>;
    increment(store: string, path: string, delta?: number): Promise<{
        storeSeq: number;
    }>;
    add(store: string, path: string, member: unknown): Promise<{
        storeSeq: number;
    }>;
    remove(store: string, path: string, member: unknown): Promise<{
        storeSeq: number;
    }>;
    on(store: string, pattern: string, callback: EventCallback): () => void;
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
    watch(store: string, pattern: string, callback: WatchCallback, opts?: {
        limit?: number;
        order?: 'asc' | 'desc';
    }): Promise<() => void>;
    enum(store: string, pattern: string): Promise<Entry[]>;
    enum(store: string, pattern: string, opts: EnumOptions & {
        select: 'keys' | 'prefixes';
    }): Promise<Page<string>>;
    enum(store: string, pattern: string, opts: EnumOptions & {
        select?: 'entries';
    }): Promise<Page<Entry>>;
    getMany(store: string, paths: string[]): Promise<Record<string, unknown>>;
    range(store: string, from: string, to: string, opts?: Omit<EnumOptions, 'select'> & {
        select?: 'entries' | 'keys';
    }): Promise<Page<Entry> | Page<string>>;
    status(store: string): Status;
    close(): void;
    private write;
    private ensureJoined;
    private doJoin;
    private registeredHandlers;
    private registerEventHandler;
    private rejoinAllStores;
    private waitForCatchUp;
    private handleChannelEvent;
    private handleEvent;
    private handleSnapshot;
    private handleCatchUpComplete;
}
declare function generateOpId(): string;
declare function inferType(value: unknown): string;

declare class Connection {
    private opts;
    private ws;
    private refCounter;
    private pendingReplies;
    private channels;
    private eventHandlers;
    private heartbeatTimer;
    private reconnectTimer;
    private reconnectAttempt;
    private closed;
    private format;
    private deviceId;
    private connectPromise;
    constructor(opts: DustOptions);
    connect(): Promise<void>;
    private doConnect;
    join(store: string, lastSeq: number): Promise<{
        storeSeq: number;
        capver: number;
        capverMin: number;
    }>;
    push(topic: string, event: string, payload: Record<string, unknown>): Promise<unknown>;
    onEvent(topic: string, handler: (event: string, payload: unknown) => void): () => void;
    close(): void;
    get connected(): boolean;
    getJoinedTopics(): string[];
    buildUrl(): string;
    private send;
    private handleMessage;
    private waitForReply;
    private startHeartbeat;
    private cleanup;
    private onReconnectCallback;
    /** Register a callback to be called after a successful reconnect. */
    onReconnect(callback: () => void): void;
    private scheduleReconnect;
    private nextRef;
}
declare function generateDeviceId(): string;

interface Cache {
    get(store: string, path: string): Entry | null;
    readEntry(store: string, path: string): Entry | null;
    readMany(store: string, paths: string[]): Record<string, Entry>;
    set(store: string, path: string, entry: Entry): void;
    delete(store: string, path: string): void;
    deletePrefix(store: string, prefix: string): void;
    entries(store: string, pattern: string): Entry[];
    browse(store: string, opts: BrowseOptions & {
        select: 'keys' | 'prefixes';
    }): Page<string>;
    browse(store: string, opts: BrowseOptions & {
        select?: 'entries';
    }): Page<Entry>;
    browse(store: string, opts: BrowseOptions): Page<Entry> | Page<string>;
    lastSeq(store: string): number;
    setLastSeq(store: string, seq: number): void;
    clear(store: string): void;
}
declare class MemoryCache implements Cache {
    private stores;
    private seqs;
    private getStore;
    get(store: string, path: string): Entry | null;
    readEntry(store: string, path: string): Entry | null;
    readMany(store: string, paths: string[]): Record<string, Entry>;
    set(store: string, path: string, entry: Entry): void;
    delete(store: string, path: string): void;
    deletePrefix(store: string, prefix: string): void;
    entries(store: string, pattern: string): Entry[];
    browse(store: string, opts: BrowseOptions & {
        select: 'keys' | 'prefixes';
    }): Page<string>;
    browse(store: string, opts: BrowseOptions & {
        select?: 'entries';
    }): Page<Entry>;
    browse(store: string, opts: BrowseOptions): Page<Entry> | Page<string>;
    lastSeq(store: string): number;
    setLastSeq(store: string, seq: number): void;
    clear(store: string): void;
}

declare function match(pattern: string, path: string): boolean;

interface WireMessage {
    joinRef: string | null;
    ref: string | null;
    topic: string;
    event: string;
    payload: unknown;
}
type Format = 'msgpack' | 'json';
declare function encode(msg: WireMessage, format: Format): Buffer | string;
declare function decode(data: Buffer | ArrayBuffer | string, format: Format): WireMessage;

export { type Cache, ConflictError, Connection, Dust, type DustOptions, type Entry, type EnumOptions, type Event, type EventCallback, type Format, MemoryCache, type Page, type PresentEvent, type Status, type WireMessage, decode, encode, generateDeviceId, generateOpId, inferType, match };
