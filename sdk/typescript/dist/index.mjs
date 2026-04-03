// src/connection.ts
import WebSocket from "ws";

// src/codec.ts
import { pack, unpack } from "msgpackr";
function encode(msg, format) {
  const arr = [msg.joinRef, msg.ref, msg.topic, msg.event, msg.payload];
  if (format === "msgpack") {
    return Buffer.from(pack(arr));
  }
  return JSON.stringify(arr);
}
function decode(data, format) {
  let arr;
  if (format === "msgpack") {
    const buf = data instanceof ArrayBuffer ? Buffer.from(data) : Buffer.from(data);
    arr = unpack(buf);
  } else {
    arr = JSON.parse(typeof data === "string" ? data : data.toString());
  }
  return {
    joinRef: arr[0],
    ref: arr[1],
    topic: arr[2],
    event: arr[3],
    payload: arr[4]
  };
}

// src/connection.ts
var Connection = class {
  constructor(opts) {
    this.opts = opts;
    this.ws = null;
    this.refCounter = 0;
    this.pendingReplies = /* @__PURE__ */ new Map();
    this.channels = /* @__PURE__ */ new Map();
    this.eventHandlers = /* @__PURE__ */ new Map();
    this.heartbeatTimer = null;
    this.reconnectTimer = null;
    this.reconnectAttempt = 0;
    this.closed = false;
    this.connectPromise = null;
    this.format = opts.format ?? "json";
    this.deviceId = opts.deviceId ?? generateDeviceId();
  }
  async connect() {
    if (this.connectPromise) return this.connectPromise;
    this.connectPromise = this.doConnect();
    return this.connectPromise;
  }
  doConnect() {
    return new Promise((resolve, reject) => {
      const url = this.buildUrl();
      const WS = typeof globalThis.WebSocket !== "undefined" ? globalThis.WebSocket : WebSocket;
      this.ws = new WS(url);
      this.ws.onopen = () => {
        this.reconnectAttempt = 0;
        this.startHeartbeat();
        resolve();
      };
      this.ws.onmessage = (evt) => {
        this.handleMessage(evt.data);
      };
      this.ws.onclose = () => {
        this.cleanup();
        if (!this.closed) this.scheduleReconnect();
      };
      this.ws.onerror = (err) => {
        if (this.connectPromise) {
          reject(err);
          this.connectPromise = null;
        }
      };
    });
  }
  async join(store, lastSeq) {
    await this.connect();
    const topic = `store:${store}`;
    const ref = this.nextRef();
    const joinRef = ref;
    this.channels.set(topic, { topic, joinRef, joined: false });
    const msg = {
      joinRef,
      ref,
      topic,
      event: "phx_join",
      payload: { last_store_seq: lastSeq }
    };
    this.send(msg);
    const reply = await this.waitForReply(ref);
    if (reply.status !== "ok") throw new Error(`Join failed: ${JSON.stringify(reply.response)}`);
    const channel = this.channels.get(topic);
    if (channel) channel.joined = true;
    return {
      storeSeq: reply.response.store_seq,
      capver: reply.response.capver,
      capverMin: reply.response.capver_min
    };
  }
  async push(topic, event, payload) {
    await this.connect();
    const channel = this.channels.get(topic);
    const ref = this.nextRef();
    const msg = {
      joinRef: channel?.joinRef ?? null,
      ref,
      topic,
      event,
      payload
    };
    this.send(msg);
    const reply = await this.waitForReply(ref);
    if (reply.status !== "ok") {
      const errorInfo = typeof reply.response === "object" && reply.response !== null ? JSON.stringify(reply.response) : String(reply.response);
      throw new Error(`Push failed: ${errorInfo}`);
    }
    return reply.response;
  }
  onEvent(topic, handler) {
    let handlers = this.eventHandlers.get(topic);
    if (!handlers) {
      handlers = /* @__PURE__ */ new Set();
      this.eventHandlers.set(topic, handlers);
    }
    handlers.add(handler);
    return () => {
      handlers.delete(handler);
    };
  }
  close() {
    this.closed = true;
    this.cleanup();
    this.ws?.close();
    this.ws = null;
  }
  get connected() {
    return this.ws?.readyState === WebSocket.OPEN;
  }
  getJoinedTopics() {
    return Array.from(this.channels.entries()).filter(([, ch]) => ch.joined).map(([topic]) => topic);
  }
  // -- Internal (exposed via buildUrl for testing) --
  buildUrl() {
    const base = new URL(this.opts.url);
    if (!base.pathname.endsWith("/websocket")) {
      base.pathname = base.pathname.replace(/\/$/, "") + "/websocket";
    }
    base.searchParams.set("token", this.opts.token);
    base.searchParams.set("device_id", this.deviceId);
    base.searchParams.set("capver", "1");
    base.searchParams.set("vsn", "2.0.0");
    return base.toString();
  }
  send(msg) {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      throw new Error("WebSocket not connected");
    }
    const data = encode(msg, this.format);
    this.ws.send(data);
  }
  handleMessage(raw) {
    const msg = decode(raw, this.format);
    switch (msg.event) {
      case "phx_reply": {
        const pending = this.pendingReplies.get(msg.ref);
        if (pending) {
          clearTimeout(pending.timeout);
          this.pendingReplies.delete(msg.ref);
          pending.resolve(msg.payload);
        }
        break;
      }
      case "phx_error": {
        const channel = this.channels.get(msg.topic);
        if (channel) channel.joined = false;
        break;
      }
      case "phx_close": {
        this.channels.delete(msg.topic);
        break;
      }
      default: {
        const handlers = this.eventHandlers.get(msg.topic);
        if (handlers) {
          for (const handler of handlers) {
            handler(msg.event, msg.payload);
          }
        }
        break;
      }
    }
  }
  waitForReply(ref, timeoutMs = 1e4) {
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pendingReplies.delete(ref);
        reject(new Error(`Timeout waiting for reply to ref ${ref}`));
      }, timeoutMs);
      this.pendingReplies.set(ref, { resolve, reject, timeout });
    });
  }
  startHeartbeat() {
    this.heartbeatTimer = setInterval(() => {
      if (this.ws?.readyState === WebSocket.OPEN) {
        const msg = {
          joinRef: null,
          ref: this.nextRef(),
          topic: "phoenix",
          event: "heartbeat",
          payload: {}
        };
        this.send(msg);
      }
    }, 3e4);
  }
  cleanup() {
    if (this.heartbeatTimer) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = null;
    }
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    for (const [, pending] of this.pendingReplies) {
      clearTimeout(pending.timeout);
      pending.reject(new Error("Connection closed"));
    }
    this.pendingReplies.clear();
    this.connectPromise = null;
    for (const channel of this.channels.values()) {
      channel.joined = false;
    }
  }
  scheduleReconnect() {
    if (this.closed) return;
    const delay = Math.min(1e3 * Math.pow(2, this.reconnectAttempt), 3e4);
    this.reconnectAttempt++;
    this.reconnectTimer = setTimeout(async () => {
      try {
        await this.doConnect();
      } catch {
        this.scheduleReconnect();
      }
    }, delay);
  }
  nextRef() {
    this.refCounter++;
    return this.refCounter.toString();
  }
};
function generateDeviceId() {
  const hex = Array.from(
    { length: 16 },
    () => Math.floor(Math.random() * 16).toString(16)
  ).join("");
  return `dev_${hex}`;
}

// src/glob.ts
function match(pattern, path) {
  const patternParts = pattern.split(".");
  const pathParts = path.split(".");
  return matchParts(patternParts, pathParts, 0, 0);
}
function matchParts(pattern, path, pi, pa) {
  if (pi === pattern.length && pa === path.length) return true;
  if (pi === pattern.length) return false;
  if (pa === path.length) {
    return false;
  }
  const seg = pattern[pi];
  if (seg === "**") {
    for (let skip = 1; skip <= path.length - pa; skip++) {
      if (matchParts(pattern, path, pi + 1, pa + skip)) return true;
    }
    return false;
  }
  if (seg === "*") {
    return matchParts(pattern, path, pi + 1, pa + 1);
  }
  if (seg === path[pa]) {
    return matchParts(pattern, path, pi + 1, pa + 1);
  }
  return false;
}

// src/cache.ts
var MemoryCache = class {
  constructor() {
    this.stores = /* @__PURE__ */ new Map();
    this.seqs = /* @__PURE__ */ new Map();
  }
  getStore(store) {
    let s = this.stores.get(store);
    if (!s) {
      s = /* @__PURE__ */ new Map();
      this.stores.set(store, s);
    }
    return s;
  }
  get(store, path) {
    return this.getStore(store).get(path) ?? null;
  }
  set(store, path, entry) {
    this.getStore(store).set(path, entry);
  }
  delete(store, path) {
    this.getStore(store).delete(path);
  }
  deletePrefix(store, prefix) {
    const s = this.getStore(store);
    for (const key of s.keys()) {
      if (key.startsWith(prefix)) {
        s.delete(key);
      }
    }
  }
  entries(store, pattern) {
    const results = [];
    for (const [path, entry] of this.getStore(store)) {
      if (match(pattern, path)) {
        results.push(entry);
      }
    }
    return results.sort((a, b) => a.path.localeCompare(b.path));
  }
  lastSeq(store) {
    return this.seqs.get(store) ?? 0;
  }
  setLastSeq(store, seq) {
    this.seqs.set(store, seq);
  }
  clear(store) {
    this.stores.delete(store);
    this.seqs.delete(store);
  }
};

// src/dust.ts
var Dust = class {
  constructor(opts) {
    this.subscriptions = /* @__PURE__ */ new Map();
    this.joinedStores = /* @__PURE__ */ new Map();
    this.catchUpComplete = /* @__PURE__ */ new Map();
    this.connection = new Connection(opts);
    this.cache = new MemoryCache();
  }
  // -- Public API --
  async get(store, path) {
    await this.ensureJoined(store);
    const entry = this.cache.get(store, path);
    return entry?.value ?? null;
  }
  async put(store, path, value) {
    return this.write(store, "set", path, value);
  }
  async merge(store, path, value) {
    return this.write(store, "merge", path, value);
  }
  async delete(store, path) {
    return this.write(store, "delete", path, null);
  }
  async increment(store, path, delta = 1) {
    return this.write(store, "increment", path, delta);
  }
  async add(store, path, member) {
    return this.write(store, "add", path, member);
  }
  async remove(store, path, member) {
    return this.write(store, "remove", path, member);
  }
  on(store, pattern, callback) {
    let subs = this.subscriptions.get(store);
    if (!subs) {
      subs = /* @__PURE__ */ new Set();
      this.subscriptions.set(store, subs);
    }
    const sub = { pattern, callback };
    subs.add(sub);
    this.ensureJoined(store);
    return () => {
      subs.delete(sub);
    };
  }
  async enum(store, pattern) {
    await this.ensureJoined(store);
    return this.cache.entries(store, pattern);
  }
  status(store) {
    return {
      connected: this.connection.connected,
      seq: this.cache.lastSeq(store)
    };
  }
  close() {
    this.connection.close();
    this.joinedStores.clear();
    this.catchUpComplete.clear();
  }
  // -- Internal --
  async write(store, op, path, value) {
    await this.ensureJoined(store);
    const topic = `store:${store}`;
    const clientOpId = generateOpId();
    const payload = {
      op,
      path,
      client_op_id: clientOpId
    };
    if (value !== null && value !== void 0) {
      payload.value = value;
    }
    const response = await this.connection.push(topic, "write", payload);
    return { storeSeq: response.store_seq };
  }
  ensureJoined(store) {
    const existing = this.joinedStores.get(store);
    if (existing) return existing;
    const promise = this.doJoin(store);
    this.joinedStores.set(store, promise);
    return promise;
  }
  async doJoin(store) {
    const topic = `store:${store}`;
    const lastSeq = this.cache.lastSeq(store);
    this.connection.onEvent(topic, (event, payload) => {
      this.handleChannelEvent(store, event, payload);
    });
    await this.connection.join(store, lastSeq);
    await this.waitForCatchUp(store);
  }
  waitForCatchUp(store) {
    if (this.catchUpComplete.get(store)) return Promise.resolve();
    return new Promise((resolve) => {
      const checkInterval = setInterval(() => {
        if (this.catchUpComplete.get(store)) {
          clearInterval(checkInterval);
          resolve();
        }
      }, 10);
      setTimeout(() => {
        clearInterval(checkInterval);
        resolve();
      }, 1e4);
    });
  }
  handleChannelEvent(store, event, payload) {
    switch (event) {
      case "event":
        this.handleEvent(store, payload);
        break;
      case "snapshot":
        this.handleSnapshot(store, payload);
        break;
      case "catch_up_complete":
        this.handleCatchUpComplete(store, payload);
        break;
    }
  }
  handleEvent(store, raw) {
    const storeSeq = raw.store_seq;
    const op = raw.op;
    const path = raw.path;
    const value = raw.value;
    const deviceId = raw.device_id;
    const clientOpId = raw.client_op_id;
    if (op === "delete") {
      this.cache.delete(store, path);
      this.cache.deletePrefix(store, path + ".");
    } else {
      const type = inferType(value);
      this.cache.set(store, path, { path, value, type, seq: storeSeq });
    }
    if (storeSeq > this.cache.lastSeq(store)) {
      this.cache.setLastSeq(store, storeSeq);
    }
    const event = { storeSeq, op, path, value, deviceId, clientOpId };
    const subs = this.subscriptions.get(store);
    if (subs) {
      for (const sub of subs) {
        if (match(sub.pattern, path)) {
          sub.callback(event);
        }
      }
    }
  }
  handleSnapshot(store, raw) {
    const snapshotSeq = raw.snapshot_seq;
    const entries = raw.entries;
    this.cache.clear(store);
    for (const [path, entry] of Object.entries(entries)) {
      this.cache.set(store, path, {
        path,
        value: entry.value,
        type: entry.type,
        seq: snapshotSeq
      });
    }
    this.cache.setLastSeq(store, snapshotSeq);
  }
  handleCatchUpComplete(store, raw) {
    const throughSeq = raw.through_seq;
    if (throughSeq > this.cache.lastSeq(store)) {
      this.cache.setLastSeq(store, throughSeq);
    }
    this.catchUpComplete.set(store, true);
  }
};
function generateOpId() {
  return Array.from(
    { length: 16 },
    () => Math.floor(Math.random() * 16).toString(16)
  ).join("");
}
function inferType(value) {
  if (value === null || value === void 0) return "null";
  if (typeof value === "boolean") return "boolean";
  if (typeof value === "number") return Number.isInteger(value) ? "integer" : "float";
  if (typeof value === "string") return "string";
  if (Array.isArray(value)) return "list";
  if (typeof value === "object") return "map";
  return "unknown";
}
export {
  Connection,
  Dust,
  MemoryCache,
  decode,
  encode,
  generateDeviceId,
  generateOpId,
  inferType,
  match
};
