import WebSocket from 'ws'
import { encode, decode, WireMessage, Format } from './codec'
import type { DustOptions } from './types'

interface PendingReply {
  resolve: (payload: unknown) => void
  reject: (error: Error) => void
  timeout: ReturnType<typeof setTimeout>
}

interface ChannelState {
  topic: string
  joinRef: string
  joined: boolean
}

export class Connection {
  private ws: WebSocket | null = null
  private refCounter = 0
  private pendingReplies = new Map<string, PendingReply>()
  private channels = new Map<string, ChannelState>()
  private eventHandlers = new Map<string, Set<(event: string, payload: unknown) => void>>()
  private heartbeatTimer: ReturnType<typeof setInterval> | null = null
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null
  private reconnectAttempt = 0
  private closed = false
  private format: Format
  private deviceId: string
  private connectPromise: Promise<void> | null = null

  constructor(private opts: DustOptions) {
    this.format = opts.format ?? 'json'
    this.deviceId = opts.deviceId ?? generateDeviceId()
  }

  async connect(): Promise<void> {
    if (this.connectPromise) return this.connectPromise
    this.connectPromise = this.doConnect()
    return this.connectPromise
  }

  private doConnect(): Promise<void> {
    return new Promise((resolve, reject) => {
      const url = this.buildUrl()
      // Use native WebSocket if available (browser/Deno/Bun), otherwise ws
      const WS = typeof globalThis.WebSocket !== 'undefined' ? globalThis.WebSocket : WebSocket
      this.ws = new WS(url) as unknown as WebSocket

      this.ws.onopen = () => {
        this.reconnectAttempt = 0
        this.startHeartbeat()
        resolve()
      }

      this.ws.onmessage = (evt: { data: unknown }) => {
        this.handleMessage(evt.data as Buffer | string)
      }

      this.ws.onclose = () => {
        this.cleanup()
        if (!this.closed) this.scheduleReconnect()
      }

      this.ws.onerror = (err: unknown) => {
        if (this.connectPromise) {
          reject(err)
          this.connectPromise = null
        }
      }
    })
  }

  async join(store: string, lastSeq: number): Promise<{ storeSeq: number; capver: number; capverMin: number }> {
    await this.connect()
    const topic = `store:${store}`
    const ref = this.nextRef()
    const joinRef = ref

    this.channels.set(topic, { topic, joinRef, joined: false })

    const msg: WireMessage = {
      joinRef,
      ref,
      topic,
      event: 'phx_join',
      payload: { last_store_seq: lastSeq },
    }
    this.send(msg)

    const reply = (await this.waitForReply(ref)) as {
      status: string
      response: Record<string, unknown>
    }
    if (reply.status !== 'ok') throw new Error(`Join failed: ${JSON.stringify(reply.response)}`)

    const channel = this.channels.get(topic)
    if (channel) channel.joined = true

    return {
      storeSeq: reply.response.store_seq as number,
      capver: reply.response.capver as number,
      capverMin: reply.response.capver_min as number,
    }
  }

  async push(topic: string, event: string, payload: Record<string, unknown>): Promise<unknown> {
    await this.connect()
    const channel = this.channels.get(topic)
    const ref = this.nextRef()

    const msg: WireMessage = {
      joinRef: channel?.joinRef ?? null,
      ref,
      topic,
      event,
      payload,
    }
    this.send(msg)

    const reply = (await this.waitForReply(ref)) as { status: string; response: unknown }
    if (reply.status !== 'ok') {
      const errorInfo =
        typeof reply.response === 'object' && reply.response !== null
          ? JSON.stringify(reply.response)
          : String(reply.response)
      throw new Error(`Push failed: ${errorInfo}`)
    }
    return reply.response
  }

  onEvent(topic: string, handler: (event: string, payload: unknown) => void): () => void {
    let handlers = this.eventHandlers.get(topic)
    if (!handlers) {
      handlers = new Set()
      this.eventHandlers.set(topic, handlers)
    }
    handlers.add(handler)
    return () => {
      handlers!.delete(handler)
    }
  }

  close(): void {
    this.closed = true
    this.cleanup()
    this.ws?.close()
    this.ws = null
  }

  get connected(): boolean {
    return this.ws?.readyState === WebSocket.OPEN
  }

  getJoinedTopics(): string[] {
    return Array.from(this.channels.entries())
      .filter(([, ch]) => ch.joined)
      .map(([topic]) => topic)
  }

  // -- Internal (exposed via buildUrl for testing) --

  buildUrl(): string {
    const base = new URL(this.opts.url)
    // Append /websocket for Phoenix transport
    if (!base.pathname.endsWith('/websocket')) {
      base.pathname = base.pathname.replace(/\/$/, '') + '/websocket'
    }
    base.searchParams.set('token', this.opts.token)
    base.searchParams.set('device_id', this.deviceId)
    base.searchParams.set('capver', '1')
    base.searchParams.set('vsn', this.format === 'msgpack' ? '3.0.0' : '2.0.0')
    return base.toString()
  }

  private send(msg: WireMessage): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      throw new Error('WebSocket not connected')
    }
    const data = encode(msg, this.format)
    this.ws.send(data)
  }

  private handleMessage(raw: Buffer | string): void {
    const msg = decode(raw, this.format)

    switch (msg.event) {
      case 'phx_reply': {
        const pending = this.pendingReplies.get(msg.ref!)
        if (pending) {
          clearTimeout(pending.timeout)
          this.pendingReplies.delete(msg.ref!)
          pending.resolve(msg.payload)
        }
        break
      }
      case 'phx_error': {
        // Channel crashed on server
        const channel = this.channels.get(msg.topic)
        if (channel) channel.joined = false
        break
      }
      case 'phx_close': {
        this.channels.delete(msg.topic)
        break
      }
      default: {
        // Broadcast events: event, snapshot, catch_up_complete, etc.
        const handlers = this.eventHandlers.get(msg.topic)
        if (handlers) {
          for (const handler of handlers) {
            handler(msg.event, msg.payload)
          }
        }
        break
      }
    }
  }

  private waitForReply(ref: string, timeoutMs = 10_000): Promise<unknown> {
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pendingReplies.delete(ref)
        reject(new Error(`Timeout waiting for reply to ref ${ref}`))
      }, timeoutMs)

      this.pendingReplies.set(ref, { resolve, reject, timeout })
    })
  }

  private startHeartbeat(): void {
    this.heartbeatTimer = setInterval(() => {
      if (this.ws?.readyState === WebSocket.OPEN) {
        const msg: WireMessage = {
          joinRef: null,
          ref: this.nextRef(),
          topic: 'phoenix',
          event: 'heartbeat',
          payload: {},
        }
        this.send(msg)
      }
    }, 30_000)
  }

  private cleanup(): void {
    if (this.heartbeatTimer) {
      clearInterval(this.heartbeatTimer)
      this.heartbeatTimer = null
    }
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer)
      this.reconnectTimer = null
    }
    for (const [, pending] of this.pendingReplies) {
      clearTimeout(pending.timeout)
      pending.reject(new Error('Connection closed'))
    }
    this.pendingReplies.clear()
    this.connectPromise = null
    // Mark all channels as not joined (will rejoin on reconnect)
    for (const channel of this.channels.values()) {
      channel.joined = false
    }
  }

  private onReconnectCallback: (() => void) | null = null

  /** Register a callback to be called after a successful reconnect. */
  onReconnect(callback: () => void): void {
    this.onReconnectCallback = callback
  }

  private scheduleReconnect(): void {
    if (this.closed) return
    const delay = Math.min(1000 * Math.pow(2, this.reconnectAttempt), 30_000)
    this.reconnectAttempt++
    this.reconnectTimer = setTimeout(async () => {
      try {
        // Use connect() (not doConnect) to respect the connectPromise guard
        await this.connect()
        this.onReconnectCallback?.()
      } catch {
        this.scheduleReconnect()
      }
    }, delay)
  }

  private nextRef(): string {
    this.refCounter++
    return this.refCounter.toString()
  }
}

export function generateDeviceId(): string {
  const hex = Array.from({ length: 16 }, () =>
    Math.floor(Math.random() * 16).toString(16),
  ).join('')
  return `dev_${hex}`
}
