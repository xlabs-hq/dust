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
    this.onReconnectCallback = null;
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
      const err = new Error(`Push failed: ${errorInfo}`);
      err.response = reply.response;
      throw err;
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
    base.searchParams.set("capver", "3");
    base.searchParams.set("vsn", this.format === "msgpack" ? "3.0.0" : "2.0.0");
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
  /** Register a callback to be called after a successful reconnect. */
  onReconnect(callback) {
    this.onReconnectCallback = callback;
  }
  scheduleReconnect() {
    if (this.closed) return;
    const delay = Math.min(1e3 * Math.pow(2, this.reconnectAttempt), 3e4);
    this.reconnectAttempt++;
    this.reconnectTimer = setTimeout(async () => {
      try {
        await this.connect();
        this.onReconnectCallback?.();
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

// src/path.ts
function fromSegments(segments) {
  if (!Array.isArray(segments)) {
    throw new Error("segments must be an array of non-empty strings");
  }
  if (segments.length === 0) {
    throw new Error("path is empty");
  }
  for (const s of segments) {
    if (typeof s !== "string") {
      throw new Error("segments must be an array of non-empty strings");
    }
    if (s === "") {
      throw new Error("segment is empty");
    }
  }
  return segments;
}
function render(segments) {
  fromSegments(segments);
  return segments.map(escapeSegment).join("/");
}
function escapeSegment(seg) {
  return seg.replace(/~/g, "~0").replace(/\//g, "~1");
}
function parseRendered(s) {
  if (typeof s !== "string") {
    throw new Error("rendered path must be a string");
  }
  if (s === "") {
    throw new Error("path is empty");
  }
  const parts = s.split("/");
  if (parts.some((p) => p === "")) {
    throw new Error(`path "${s}" contains empty segments`);
  }
  return parts.map(unescapeSegment);
}
function unescapeSegment(seg) {
  let out = "";
  let i = 0;
  while (i < seg.length) {
    const ch = seg[i];
    if (ch === "~") {
      const next = seg[i + 1];
      if (next === "0") {
        out += "~";
        i += 2;
      } else if (next === "1") {
        out += "/";
        i += 2;
      } else {
        throw new Error(`invalid escape "~${next ?? ""}" in segment "${seg}"`);
      }
    } else {
      out += ch;
      i += 1;
    }
  }
  return out;
}
function normalizeRendered(s) {
  return render(parseRendered(s));
}
function parseLegacyDotted(s) {
  if (s === "") throw new Error("path is empty");
  const parts = s.split(".");
  if (parts.some((p) => p === "")) {
    throw new Error(`legacy path "${s}" contains empty segments`);
  }
  return parts;
}
function normalizePath(path) {
  if (Array.isArray(path)) {
    return render(fromSegments(path));
  }
  if (typeof path !== "string") {
    throw new Error("path must be a string or array of strings");
  }
  return normalizeRendered(path);
}
function normalizePattern(pattern) {
  if (pattern === "**") return "**";
  if (typeof pattern !== "string") {
    throw new Error("pattern must be a string");
  }
  const parts = pattern.split("/");
  if (parts.some((p) => p === "")) {
    throw new Error(`pattern "${pattern}" contains empty segments`);
  }
  return pattern;
}

// src/glob.ts
function compile(input) {
  const segments = typeof input === "string" ? parseRendered(input) : fromSegments(input);
  const tokens = segments.map(classifySegment);
  for (let i = 0; i < tokens.length; i++) {
    if (tokens[i].kind === "many" && i !== tokens.length - 1) {
      throw new Error("** is only valid in the tail position of a glob pattern");
    }
  }
  return { tokens };
}
function classifySegment(seg) {
  if (seg === "*") return { kind: "one" };
  if (seg === "**") return { kind: "many" };
  if (seg === "\\*") return { kind: "literal", value: "*" };
  if (seg === "\\**") return { kind: "literal", value: "**" };
  return { kind: "literal", value: seg };
}
function match(pattern, path) {
  const compiled = isCompiled(pattern) ? pattern : compile(pattern);
  return walk(compiled.tokens, 0, path, 0);
}
function isCompiled(v) {
  return typeof v === "object" && v !== null && Array.isArray(v.tokens);
}
function walk(tokens, ti, path, pi) {
  if (ti === tokens.length && pi === path.length) return true;
  if (ti === tokens.length - 1 && tokens[ti].kind === "many") {
    return pi < path.length;
  }
  if (ti === tokens.length || pi === path.length) return false;
  const t = tokens[ti];
  if (t.kind === "one") {
    return walk(tokens, ti + 1, path, pi + 1);
  }
  if (t.kind === "literal") {
    return t.value === path[pi] && walk(tokens, ti + 1, path, pi + 1);
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
  readEntry(store, path) {
    return this.stores.get(store)?.get(path) ?? null;
  }
  readMany(store, paths) {
    const storeMap = this.stores.get(store);
    if (!storeMap) return {};
    const result = {};
    const seen = /* @__PURE__ */ new Set();
    for (const path of paths) {
      if (seen.has(path)) continue;
      seen.add(path);
      const entry = storeMap.get(path);
      if (entry) result[path] = entry;
    }
    return result;
  }
  set(store, path, entry) {
    this.getStore(store).set(path, { ...entry, syncedAt: Date.now() });
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
    const compiled = compile(pattern);
    const results = [];
    for (const [_path, entry] of this.getStore(store)) {
      if (matchPath(compiled, entry.path)) {
        results.push(entry);
      }
    }
    return results.sort((a, b) => a.path.localeCompare(b.path));
  }
  browse(store, opts) {
    const pattern = opts.pattern ?? "**";
    const limit = opts.limit ?? 50;
    const order = opts.order ?? "asc";
    const select = opts.select ?? "entries";
    if (select === "prefixes") {
      if (pattern !== "**" && !pattern.endsWith("/**")) {
        throw new Error("select: prefixes requires pattern ending in /** or **");
      }
    }
    const storeMap = this.stores.get(store);
    if (!storeMap) return { items: [], nextCursor: null };
    let entries = Array.from(storeMap.values());
    if (opts.from !== void 0 && opts.to !== void 0) {
      const from = opts.from;
      const to = opts.to;
      entries = entries.filter((e) => e.path >= from && e.path < to);
    } else {
      const compiled = compile(pattern);
      entries = entries.filter((e) => matchPath(compiled, e.path));
    }
    entries.sort(
      (a, b) => order === "asc" ? a.path.localeCompare(b.path) : b.path.localeCompare(a.path)
    );
    if (opts.after !== void 0) {
      const after = opts.after;
      entries = order === "asc" ? entries.filter((e) => e.path > after) : entries.filter((e) => e.path < after);
    }
    const slice = entries.slice(0, limit + 1);
    const hasMore = slice.length > limit;
    const pageItems = hasMore ? slice.slice(0, limit) : slice;
    const nextCursor = hasMore && pageItems.length > 0 ? pageItems[pageItems.length - 1].path : null;
    if (select === "entries") {
      return { items: pageItems, nextCursor };
    } else if (select === "keys") {
      return { items: pageItems.map((e) => e.path), nextCursor };
    } else {
      return { items: prefixesOf(pageItems, pattern), nextCursor };
    }
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
function prefixesOf(entries, pattern) {
  const literal = literalPrefixOf(pattern);
  const seen = /* @__PURE__ */ new Set();
  for (const entry of entries) {
    const prefix = extractPrefix(entry.path, literal);
    if (prefix !== null) seen.add(prefix);
  }
  return Array.from(seen).sort();
}
function literalPrefixOf(pattern) {
  if (pattern === "**") return "";
  return pattern.replace(/\/\*\*$/, "");
}
function extractPrefix(path, literal) {
  if (literal === "") {
    const i2 = path.indexOf("/");
    return i2 === -1 ? path : path.slice(0, i2);
  }
  const prefix = literal + "/";
  if (!path.startsWith(prefix)) return null;
  const rest = path.slice(prefix.length);
  const i = rest.indexOf("/");
  return literal + "/" + (i === -1 ? rest : rest.slice(0, i));
}
function matchPath(compiled, path) {
  try {
    return match(compiled, parseRendered(path));
  } catch {
    return false;
  }
}

// src/types.ts
var ConflictError = class extends Error {
  constructor(currentRevision = null) {
    super("conflict");
    this.name = "ConflictError";
    this.currentRevision = currentRevision;
  }
};
var ExistsError = class extends Error {
  constructor(currentRevision = null) {
    super("exists");
    this.name = "ExistsError";
    this.currentRevision = currentRevision;
  }
};
var LeaseError = class extends Error {
  constructor(reason) {
    super(reason);
    this.name = "LeaseError";
    this.reason = reason;
  }
};
var SingleFlightAbort = class extends Error {
  constructor(reason) {
    super("single_flight aborted");
    this.name = "SingleFlightAbort";
    this.reason = reason;
  }
};
var SingleFlightTimeout = class extends Error {
  constructor() {
    super("single_flight wait timed out");
    this.name = "SingleFlightTimeout";
  }
};

// src/dust.ts
var sleep = (ms) => new Promise((r) => setTimeout(r, ms));
var Dust = class {
  constructor(opts) {
    this.subscriptions = /* @__PURE__ */ new Map();
    this.joinedStores = /* @__PURE__ */ new Map();
    this.catchUpComplete = /* @__PURE__ */ new Map();
    this.registeredHandlers = /* @__PURE__ */ new Set();
    this.connection = new Connection(opts);
    this.cache = new MemoryCache();
    this.connection.onReconnect(() => {
      this.rejoinAllStores();
    });
  }
  // -- Public API --
  //
  // Path arguments accept either a canonical slash-rendered string
  // (`"posts/hello"`) or a segment array (`["posts", "hello"]`). Both
  // are validated and normalised at the boundary; internally the
  // SDK always speaks canonical slash form.
  async get(store, path) {
    const normalized = normalizePath(path);
    await this.ensureJoined(store);
    const entry = this.cache.get(store, normalized);
    return entry?.value ?? null;
  }
  async entry(store, path) {
    const normalized = normalizePath(path);
    await this.ensureJoined(store);
    return this.cache.readEntry(store, normalized);
  }
  async put(store, path, value, opts) {
    return this.write(store, "set", normalizePath(path), value, opts);
  }
  /**
   * Acquire (or steal an expired) lease at `key`. Returns the {@link Lease} on
   * acquisition, `null` if a live lease is held by someone else. Throws
   * {@link LeaseError} (`occupied` | `unavailable`) for the exceptional cases.
   */
  async lease(store, key, opts = {}) {
    const payload = { ttl_ms: opts.ttlMs ?? 3e4 };
    if (opts.holder !== void 0) payload.holder = opts.holder;
    const reply = await this.leaseWrite(store, "lease", normalizePath(key), payload);
    switch (reply.kind) {
      case "ok":
        return leaseFromReply(normalizePath(key), reply.resp);
      case "held":
      case "not_held":
        return null;
      default:
        throw new LeaseError(reply.reason);
    }
  }
  /** Extend a held lease (keeps its token). `null` if it was lost. */
  async renew(store, lease, opts = {}) {
    const reply = await this.leaseWrite(store, "renew", lease.key, {
      token: lease.token,
      ttl_ms: opts.ttlMs ?? 3e4
    });
    switch (reply.kind) {
      case "ok":
        return leaseFromReply(lease.key, reply.resp, lease.holder);
      case "held":
      case "not_held":
        return null;
      default:
        throw new LeaseError(reply.reason);
    }
  }
  /** Release a held lease. Idempotent — a lost/stale token is a no-op. */
  async release(store, lease) {
    await this.leaseWrite(store, "release", lease.key, { token: lease.token });
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
  async singleFlight(store, key, fn, opts = {}) {
    const cfg = {
      fresh: opts.fresh,
      leaseTtl: opts.leaseTtl ?? 3e4,
      waitTimeout: opts.waitTimeout ?? (opts.leaseTtl ?? 3e4) + 5e3,
      onUnavailable: opts.onUnavailable ?? "runLocal",
      lockKey: opts.lockKey ?? `_dust:sf/${key}`
    };
    const cached = await this.lastValue(store, key);
    if (cached.hit && (!cfg.fresh || cfg.fresh(cached.value))) {
      return { value: cached.value, source: "cached", stale: false, coordinated: true };
    }
    return this.sfCoordinate(store, key, fn, cfg, Date.now() + cfg.waitTimeout);
  }
  async sfCoordinate(store, key, fn, cfg, deadline) {
    let lease;
    try {
      lease = await this.lease(store, cfg.lockKey, { ttlMs: cfg.leaseTtl });
    } catch (err) {
      if (err instanceof LeaseError && err.reason === "unavailable") {
        return this.sfDegraded(store, key, fn, cfg);
      }
      throw err;
    }
    if (lease) return this.sfWon(store, key, fn, lease, cfg);
    const r = await this.sfAwait(store, key, cfg, deadline);
    if (r !== "retry") return r;
    if (Date.now() < deadline) {
      await sleep(Math.floor(Math.random() * 250) + 1);
      return this.sfCoordinate(store, key, fn, cfg, deadline);
    }
    return this.sfOnTimeout(store, key, cfg);
  }
  async sfWon(store, key, fn, lease, cfg) {
    const hb = this.startHeartbeat(store, lease, cfg.leaseTtl);
    let result;
    try {
      result = await fn(lease);
    } finally {
      clearInterval(hb);
    }
    if (result && "publish" in result) {
      try {
        await this.put(store, key, JSON.stringify(result.publish), { fence: lease });
      } catch (err) {
        if (err instanceof LeaseError && err.reason === "fenced") throw err;
        await this.release(store, lease).catch(() => {
        });
        throw err;
      }
      await this.release(store, lease);
      const value = JSON.parse(JSON.stringify(result.publish));
      return { value, source: "computed", stale: false, coordinated: true };
    }
    await this.release(store, lease);
    throw new SingleFlightAbort(result.abort);
  }
  async sfAwait(store, key, cfg, deadline) {
    let resolveFn;
    const promise = new Promise((res) => resolveFn = res);
    let settled = false;
    let timer;
    const unsubs = [];
    const finish = (v) => {
      if (settled) return;
      settled = true;
      unsubs.forEach((u) => u());
      if (timer) clearTimeout(timer);
      resolveFn(v);
    };
    const tryKey = async () => {
      const c = await this.lastValue(store, key);
      if (c.hit && (!cfg.fresh || cfg.fresh(c.value))) {
        finish({ value: c.value, source: "awaited", stale: false, coordinated: true });
      }
    };
    unsubs.push(this.subscribeRaw(store, key, () => void tryKey()));
    unsubs.push(
      this.subscribeRaw(store, cfg.lockKey, (ev) => {
        if (ev.op === "release") finish("retry");
      })
    );
    await tryKey();
    if (!settled) {
      const wait = Math.min(cfg.leaseTtl, deadline - Date.now());
      if (wait <= 0) finish("retry");
      else timer = setTimeout(() => finish("retry"), wait);
    }
    return promise;
  }
  async sfDegraded(store, key, fn, cfg) {
    if (cfg.onUnavailable === "error") throw new LeaseError("unavailable");
    const result = await fn(null);
    if (result && "publish" in result) {
      void this.put(store, key, JSON.stringify(result.publish)).catch(() => {
      });
      const value = JSON.parse(JSON.stringify(result.publish));
      return { value, source: "computed", stale: false, coordinated: false };
    }
    throw new SingleFlightAbort(result.abort);
  }
  async sfOnTimeout(store, key, cfg) {
    const c = await this.lastValue(store, key);
    if (c.hit && cfg.fresh) {
      return { value: c.value, source: "cached", stale: true, coordinated: true };
    }
    throw new SingleFlightTimeout();
  }
  async lastValue(store, key) {
    const entry = await this.entry(store, key);
    if (entry && entry.type !== "lease" && typeof entry.value === "string") {
      return { hit: true, value: JSON.parse(entry.value) };
    }
    return { hit: false };
  }
  startHeartbeat(store, lease, ttl) {
    const interval = Math.max(Math.floor(ttl / 3), 1);
    return setInterval(() => {
      void this.renew(store, lease, { ttlMs: ttl }).catch(() => {
      });
    }, interval);
  }
  // Lightweight ongoing subscription (no bootstrap) used by singleFlight's
  // await. Returns an unsubscribe fn.
  subscribeRaw(store, pattern, callback) {
    let subs = this.subscriptions.get(store);
    if (!subs) {
      subs = /* @__PURE__ */ new Set();
      this.subscriptions.set(store, subs);
    }
    const sub = { pattern: normalizePattern(pattern), callback, bootstrapPending: false };
    subs.add(sub);
    return () => subs.delete(sub);
  }
  async merge(store, path, value) {
    return this.write(store, "merge", normalizePath(path), value);
  }
  async delete(store, path) {
    return this.write(store, "delete", normalizePath(path), null);
  }
  async increment(store, path, delta = 1) {
    return this.write(store, "increment", normalizePath(path), delta);
  }
  async add(store, path, member) {
    return this.write(store, "add", normalizePath(path), member);
  }
  async remove(store, path, member) {
    return this.write(store, "remove", normalizePath(path), member);
  }
  on(store, pattern, callback) {
    pattern = normalizePattern(pattern);
    let subs = this.subscriptions.get(store);
    if (!subs) {
      subs = /* @__PURE__ */ new Set();
      this.subscriptions.set(store, subs);
    }
    const sub = { pattern, callback };
    subs.add(sub);
    this.ensureJoined(store).catch(() => {
    });
    return () => {
      subs.delete(sub);
    };
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
  async watch(store, pattern, callback, opts = {}) {
    pattern = normalizePattern(pattern);
    const limit = Math.min(opts.limit ?? 50, 1e3);
    const order = opts.order ?? "asc";
    const sub = {
      pattern,
      callback,
      bootstrapPending: true,
      pendingEvents: []
    };
    let storeSubs = this.subscriptions.get(store);
    if (!storeSubs) {
      storeSubs = /* @__PURE__ */ new Set();
      this.subscriptions.set(store, storeSubs);
    }
    storeSubs.add(sub);
    const unsubscribe = () => {
      storeSubs.delete(sub);
    };
    try {
      await this.ensureJoined(store);
      const page = this.cache.browse(store, {
        pattern,
        limit,
        order,
        select: "entries"
      });
      for (const entry of page.items) {
        callback({
          op: "present",
          path: entry.path,
          value: entry.value,
          type: entry.type,
          seq: entry.seq
        });
      }
      for (const event of sub.pendingEvents) {
        callback(event);
      }
      sub.pendingEvents = [];
      sub.bootstrapPending = false;
    } catch (err) {
      unsubscribe();
      throw err;
    }
    return unsubscribe;
  }
  async enum(store, pattern, opts) {
    pattern = normalizePattern(pattern);
    await this.ensureJoined(store);
    if (opts === void 0) {
      return this.cache.entries(store, pattern);
    }
    return this.cache.browse(store, { ...opts, pattern });
  }
  async getMany(store, paths) {
    if (paths.length > 1e3) {
      throw new Error("getMany: maximum 1000 paths per call");
    }
    const normalized = paths.map(normalizePath);
    await this.ensureJoined(store);
    const raw = this.cache.readMany(store, normalized);
    const result = {};
    for (const [path, entry] of Object.entries(raw)) {
      result[path] = entry.value;
    }
    return result;
  }
  async range(store, from, to, opts = {}) {
    if (opts.select === "prefixes") {
      throw new Error("range: select prefixes is not supported");
    }
    const fromNorm = normalizePath(from);
    const toNorm = normalizePath(to);
    await this.ensureJoined(store);
    return this.cache.browse(store, { ...opts, from: fromNorm, to: toNorm });
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
  async write(store, op, path, value, opts) {
    await this.ensureJoined(store);
    const topic = `store:${store}`;
    const clientOpId = generateOpId();
    const payload = {
      op,
      path,
      path_segments: parseRendered(path),
      client_op_id: clientOpId
    };
    if (value !== null && value !== void 0) {
      payload.value = value;
    }
    if (opts && typeof opts.ifMatch === "number") {
      payload.if_match = opts.ifMatch;
    }
    if (opts && opts.ifAbsent === true) {
      payload.if_absent = true;
    }
    if (opts && opts.fence) {
      payload.fence = { key: opts.fence.key, token: opts.fence.token };
    }
    let response;
    try {
      response = await this.connection.push(topic, "write", payload);
    } catch (err) {
      const resp = err?.response;
      if (resp !== null && typeof resp === "object") {
        const reason = resp.reason;
        const current = resp.current_revision;
        const currentRevision = typeof current === "number" ? current : null;
        if (reason === "conflict") {
          throw new ConflictError(currentRevision);
        }
        if (reason === "exists") {
          throw new ExistsError(currentRevision);
        }
        if (reason === "fenced") {
          throw new LeaseError("fenced");
        }
      }
      throw err;
    }
    return { storeSeq: response.store_seq };
  }
  // Push a lease op and classify the reply. Ordinary contention (held /
  // not_held) is a normal outcome, not an error; occupied/unavailable surface
  // as LeaseError to callers.
  async leaseWrite(store, op, key, fields) {
    await this.ensureJoined(store);
    const payload = {
      op,
      path: key,
      path_segments: parseRendered(key),
      client_op_id: generateOpId(),
      ...fields
    };
    try {
      const resp = await this.connection.push(`store:${store}`, "write", payload);
      return { kind: "ok", resp };
    } catch (err) {
      const resp = err?.response;
      const reason = resp !== null && typeof resp === "object" ? resp.reason : void 0;
      if (reason === "held") return { kind: "held" };
      if (reason === "not_held") return { kind: "not_held" };
      if (reason === "occupied") return { kind: "error", reason: "occupied" };
      return { kind: "error", reason: "unavailable" };
    }
  }
  ensureJoined(store) {
    const existing = this.joinedStores.get(store);
    if (existing) return existing;
    const promise = this.doJoin(store).catch((err) => {
      this.joinedStores.delete(store);
      throw err;
    });
    this.joinedStores.set(store, promise);
    return promise;
  }
  async doJoin(store) {
    const topic = `store:${store}`;
    const lastSeq = this.cache.lastSeq(store);
    this.registerEventHandler(store);
    this.catchUpComplete.delete(store);
    await this.connection.join(store, lastSeq);
    await this.waitForCatchUp(store);
  }
  registerEventHandler(store) {
    const topic = `store:${store}`;
    if (this.registeredHandlers.has(topic)) return;
    this.registeredHandlers.add(topic);
    this.connection.onEvent(topic, (event, payload) => {
      this.handleChannelEvent(store, event, payload);
    });
  }
  rejoinAllStores() {
    const stores = Array.from(this.joinedStores.keys());
    this.joinedStores.clear();
    this.catchUpComplete.clear();
    for (const store of stores) {
      this.ensureJoined(store).catch(() => {
      });
    }
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
    if (op === "delete" || op === "release") {
      this.cache.delete(store, path);
      this.cache.deletePrefix(store, path + "/");
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
      let pathSegments;
      try {
        pathSegments = parseRendered(path);
      } catch {
        return;
      }
      for (const sub of subs) {
        if (match(sub.pattern, pathSegments)) {
          if (sub.bootstrapPending) {
            sub.pendingEvents.push(event);
          } else {
            sub.callback(event);
          }
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
function leaseFromReply(key, resp, fallbackHolder = null) {
  return {
    key,
    token: resp.token,
    holder: resp.holder ?? fallbackHolder,
    expiresAt: resp.expires_at
  };
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
  ConflictError,
  Connection,
  Dust,
  ExistsError,
  LeaseError,
  MemoryCache,
  SingleFlightAbort,
  SingleFlightTimeout,
  compile,
  decode,
  encode,
  fromSegments,
  generateDeviceId,
  generateOpId,
  inferType,
  match,
  parseLegacyDotted,
  parseRendered,
  render
};
