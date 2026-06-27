/**
 * Segment-first paths for the Dust TypeScript SDK.
 *
 * A path is a non-empty array of non-empty string segments:
 *
 *     ["posts", "hello.world", "image/file"]
 *
 * Public SDK functions accept either a segment array or a canonical
 * rendered slash string (see `fromInput`). Internally the SDK uses
 * segment arrays; strings are rendered at boundaries (cache keys,
 * wire protocol, log lines).
 *
 * Mirrors `DustProtocol.Path` from the canonical wire-protocol
 * package.
 *
 * ## Rendering
 *
 * Canonical rendered paths join segments with `/` and escape per RFC
 * 6901 (JSON Pointer) inside each segment:
 *
 *     `~` -> `~0`
 *     `/` -> `~1`
 *
 * No other character has any special meaning. In particular, `.` is
 * literal — `"example.com"` is one segment, not two.
 */
type Segments = string[];
type PathInput = string | Segments;
/**
 * Validate a segment array. Throws if it's empty, contains an
 * empty string, or contains non-string entries.
 */
declare function fromSegments(segments: Segments): Segments;
/**
 * Render a segment array to canonical slash form, escaping `~` and
 * `/` inside each segment per RFC 6901.
 *
 * `~` must be escaped first or the `/` -> `~1` substitution would
 * create false `~1` sequences in subsequent decoding.
 */
declare function render(segments: Segments): string;
/**
 * Parse a canonical rendered path into segments. Rejects empty paths,
 * empty segments (leading/trailing/double slash), and invalid `~`
 * escapes.
 */
declare function parseRendered(s: string): Segments;
declare function parseLegacyDotted(s: string): Segments;

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
    /**
     * Local wall-clock (unix epoch ms) when this mirror last wrote the row
     * from a sync event. `null` for entries that were never stamped (e.g.
     * subtree-assembled values).
     */
    syncedAt: number | null;
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
    get(store: string, path: PathInput): Promise<unknown>;
    entry(store: string, path: PathInput): Promise<Entry | null>;
    put(store: string, path: PathInput, value: unknown, opts?: {
        ifMatch?: number;
    }): Promise<{
        storeSeq: number;
    }>;
    merge(store: string, path: PathInput, value: Record<string, unknown>): Promise<{
        storeSeq: number;
    }>;
    delete(store: string, path: PathInput): Promise<{
        storeSeq: number;
    }>;
    increment(store: string, path: PathInput, delta?: number): Promise<{
        storeSeq: number;
    }>;
    add(store: string, path: PathInput, member: unknown): Promise<{
        storeSeq: number;
    }>;
    remove(store: string, path: PathInput, member: unknown): Promise<{
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
    getMany(store: string, paths: PathInput[]): Promise<Record<string, unknown>>;
    range(store: string, from: PathInput, to: PathInput, opts?: Omit<EnumOptions, 'select'> & {
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
    set(store: string, path: string, entry: Omit<Entry, 'syncedAt'>): void;
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
    set(store: string, path: string, entry: Omit<Entry, 'syncedAt'>): void;
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

/**
 * Segment-aware glob matching against `path.ts` segment arrays.
 *
 * Mirrors `DustProtocol.Glob` from the canonical wire-protocol
 * package.
 *
 * ## Pattern grammar
 *
 * A pattern is a non-empty array of pattern segments. Each segment is
 * either:
 *
 *   - `"*"` — matches exactly one path segment
 *   - `"**"` — matches one or more path segments; **only valid in the
 *     tail position**
 *   - `"\*"` — matches a path segment that is literally `"*"`
 *   - `"\**"` — matches a path segment that is literally `"**"`
 *   - any other string — matches that exact path segment
 *
 * Patterns can also be given as rendered slash strings, decoded with
 * the same JSON Pointer escape rules as `path.ts`.
 */

type Token = {
    kind: 'literal';
    value: string;
} | {
    kind: 'one';
} | {
    kind: 'many';
};
interface Compiled {
    readonly tokens: ReadonlyArray<Token>;
}
declare function compile(input: PathInput): Compiled;
/**
 * Test whether a (compiled or raw) pattern matches a segment-array
 * path. If `pattern` is a string or array, it is compiled on the
 * fly; compile errors propagate.
 */
declare function match(pattern: Compiled | PathInput, path: Segments): boolean;

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

export { type Cache, ConflictError, Connection, Dust, type DustOptions, type Entry, type EnumOptions, type Event, type EventCallback, type Format, MemoryCache, type Page, type PathInput, type PresentEvent, type Segments, type Status, type WireMessage, compile, decode, encode, fromSegments, generateDeviceId, generateOpId, inferType, match, parseLegacyDotted, parseRendered, render };
