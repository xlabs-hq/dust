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
interface Event {
    storeSeq: number;
    op: string;
    path: string;
    value: unknown;
    deviceId: string;
    clientOpId: string;
}
interface Status {
    connected: boolean;
    seq: number;
}
type EventCallback = (event: Event) => void;

declare class Dust {
    private connection;
    private cache;
    private subscriptions;
    private joinedStores;
    private catchUpComplete;
    constructor(opts: DustOptions);
    get(store: string, path: string): Promise<unknown>;
    put(store: string, path: string, value: unknown): Promise<{
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
    enum(store: string, pattern: string): Promise<Entry[]>;
    status(store: string): Status;
    close(): void;
    private write;
    private ensureJoined;
    private doJoin;
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
    private scheduleReconnect;
    private nextRef;
}
declare function generateDeviceId(): string;

interface Cache {
    get(store: string, path: string): Entry | null;
    set(store: string, path: string, entry: Entry): void;
    delete(store: string, path: string): void;
    deletePrefix(store: string, prefix: string): void;
    entries(store: string, pattern: string): Entry[];
    lastSeq(store: string): number;
    setLastSeq(store: string, seq: number): void;
    clear(store: string): void;
}
declare class MemoryCache implements Cache {
    private stores;
    private seqs;
    private getStore;
    get(store: string, path: string): Entry | null;
    set(store: string, path: string, entry: Entry): void;
    delete(store: string, path: string): void;
    deletePrefix(store: string, prefix: string): void;
    entries(store: string, pattern: string): Entry[];
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

export { type Cache, Connection, Dust, type DustOptions, type Entry, type Event, type EventCallback, type Format, MemoryCache, type Status, type WireMessage, decode, encode, generateDeviceId, generateOpId, inferType, match };
