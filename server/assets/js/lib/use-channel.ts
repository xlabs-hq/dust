import { useEffect, useRef, useState } from "react"
import { Socket, Channel } from "phoenix"

interface UseChannelOptions {
  token: string | null
  topic: string
}

interface UseChannelResult {
  channel: Channel | null
  connected: boolean
  error: string | null
}

/**
 * Connect to a Phoenix Channel via the UI socket.
 *
 * @example
 * const { channel, connected } = useChannel({
 *   token: socket_token,
 *   topic: `ui:store:${store.full_name}`,
 * })
 */
export function useChannel({ token, topic }: UseChannelOptions): UseChannelResult {
  const socketRef = useRef<Socket | null>(null)
  const channelRef = useRef<Channel | null>(null)
  const [connected, setConnected] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (!token) {
      setError("No socket token available")
      return
    }

    const socket = new Socket("/ws/ui", { params: { token } })
    socket.onError(() => {
      setError("Socket connection error")
      setConnected(false)
    })
    socket.onClose(() => setConnected(false))
    socket.connect()
    socketRef.current = socket

    const channel = socket.channel(topic, {})
    channelRef.current = channel

    channel
      .join()
      .receive("ok", () => {
        setConnected(true)
        setError(null)
      })
      .receive("error", (resp) => {
        setError(`Failed to join channel: ${JSON.stringify(resp)}`)
        setConnected(false)
      })
      .receive("timeout", () => {
        setError("Channel join timeout")
        setConnected(false)
      })

    return () => {
      channel.leave()
      socket.disconnect()
      socketRef.current = null
      channelRef.current = null
    }
  }, [token, topic])

  return { channel: channelRef.current, connected, error }
}

/**
 * Subscribe to a specific event on a channel.
 *
 * @example
 * useChannelEvent(channel, "changed", () => {
 *   router.reload({ only: ["entries", "ops"] })
 * })
 */
export function useChannelEvent<T = unknown>(
  channel: Channel | null,
  event: string,
  handler: (payload: T) => void
) {
  const handlerRef = useRef(handler)
  handlerRef.current = handler

  useEffect(() => {
    if (!channel) return

    const ref = channel.on(event, (payload: T) => {
      handlerRef.current(payload)
    })

    return () => {
      channel.off(event, ref)
    }
  }, [channel, event])
}
