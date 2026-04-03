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
export {
  Connection,
  generateDeviceId
};
