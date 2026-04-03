"use strict";
var __create = Object.create;
var __defProp = Object.defineProperty;
var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
var __getOwnPropNames = Object.getOwnPropertyNames;
var __getProtoOf = Object.getPrototypeOf;
var __hasOwnProp = Object.prototype.hasOwnProperty;
var __export = (target, all) => {
  for (var name in all)
    __defProp(target, name, { get: all[name], enumerable: true });
};
var __copyProps = (to, from, except, desc) => {
  if (from && typeof from === "object" || typeof from === "function") {
    for (let key of __getOwnPropNames(from))
      if (!__hasOwnProp.call(to, key) && key !== except)
        __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
  }
  return to;
};
var __toESM = (mod, isNodeMode, target) => (target = mod != null ? __create(__getProtoOf(mod)) : {}, __copyProps(
  // If the importer is in node compatibility mode or this is not an ESM
  // file that has been converted to a CommonJS file using a Babel-
  // compatible transform (i.e. "__esModule" has not been set), then set
  // "default" to the CommonJS "module.exports" for node compatibility.
  isNodeMode || !mod || !mod.__esModule ? __defProp(target, "default", { value: mod, enumerable: true }) : target,
  mod
));
var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);

// src/index.ts
var index_exports = {};
__export(index_exports, {
  Connection: () => Connection,
  generateDeviceId: () => generateDeviceId
});
module.exports = __toCommonJS(index_exports);

// src/connection.ts
var import_ws = __toESM(require("ws"));

// src/codec.ts
var import_msgpackr = require("msgpackr");
function encode(msg, format) {
  const arr = [msg.joinRef, msg.ref, msg.topic, msg.event, msg.payload];
  if (format === "msgpack") {
    return Buffer.from((0, import_msgpackr.pack)(arr));
  }
  return JSON.stringify(arr);
}
function decode(data, format) {
  let arr;
  if (format === "msgpack") {
    const buf = data instanceof ArrayBuffer ? Buffer.from(data) : Buffer.from(data);
    arr = (0, import_msgpackr.unpack)(buf);
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
      const WS = typeof globalThis.WebSocket !== "undefined" ? globalThis.WebSocket : import_ws.default;
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
    return this.ws?.readyState === import_ws.default.OPEN;
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
    if (!this.ws || this.ws.readyState !== import_ws.default.OPEN) {
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
      if (this.ws?.readyState === import_ws.default.OPEN) {
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
// Annotate the CommonJS export names for ESM import in node:
0 && (module.exports = {
  Connection,
  generateDeviceId
});
