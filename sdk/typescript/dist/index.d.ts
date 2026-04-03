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

export { Connection, type DustOptions, type Entry, type Event, type EventCallback, type Status, generateDeviceId };
