# Stage 4 — WebSocket Connection

## Overview

`PyreClient.Connection` is the WebSockex process that owns the WebSocket lifecycle. It handles:

1. Connecting to the Pyre Web server
2. WebSocket-level ping/pong keepalive (dead connection detection)
3. Phoenix-level heartbeats (server-side timeout prevention)
4. Reconnection with backoff
5. Delegating decoded messages to the Channel layer

## Two Levels of Keepalive

There are two distinct keepalive mechanisms, and we need both:

### 1. WebSocket Ping/Pong (Transport Layer)

**Problem**: WebSockex doesn't detect dead TCP connections after network outages (issue #129). The OS TCP keepalive has a default timeout of 2+ hours.

**Solution**: Send WebSocket-level `{:ping, ""}` frames every 20 seconds. If no `{:pong, _}` is received before the next ping, the connection is dead — close and reconnect.

This operates at the WebSocket frame level, below Phoenix channels.

### 2. Phoenix Heartbeat (Application Layer)

**Problem**: The Phoenix server closes channels that don't send a heartbeat within 60 seconds (default `transport_timeout`).

**Solution**: Send a Phoenix heartbeat message (`[null, ref, "phoenix", "heartbeat", {}]`) every 30 seconds. The server replies with `phx_reply`.

This operates at the Phoenix channel protocol level, above WebSocket frames.

### Why Both?

| Mechanism | Detects | Interval | Level |
|-----------|---------|----------|-------|
| WS ping/pong | Dead TCP connection | 20s | Transport |
| Phoenix heartbeat | Server-side channel timeout | 30s | Application |

A dead connection won't respond to either, but the WS ping/pong detects it faster (20s vs 30s). The Phoenix heartbeat is required regardless — even on a healthy connection, the server will disconnect you without it.

## Module: `PyreClient.Connection`

```elixir
defmodule PyreClient.Connection do
  @moduledoc """
  WebSocket connection to a Pyre Web server.

  Manages the WebSocket lifecycle, keepalive (both WebSocket ping/pong
  and Phoenix heartbeats), and reconnection. Delegates decoded Phoenix
  Channel messages to `PyreClient.Channel`.
  """
  use WebSockex

  require Logger

  alias PyreClient.Protocol
  alias PyreClient.Protocol.Message
  alias PyreClient.Channel

  defstruct [
    # WebSocket ping/pong state
    :pong_received,
    :ping_timer,
    # Phoenix heartbeat state
    :heartbeat_timer,
    :pending_heartbeat_ref,
    # Channel state (delegated to Channel module)
    :channel,
    # Connection metadata
    :server_url,
    :connection_id,
    :connected
  ]

  # --- Child Spec / Start ---

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []},
      restart: :permanent,
      type: :worker
    }
  end

  def start_link do
    url = PyreClient.Config.server_url()
    connection_id = PyreClient.Config.connection_id()

    # Append connection_id as query param for socket connect
    url_with_params = append_params(url, %{"connection_id" => connection_id})

    state = %__MODULE__{
      pong_received: true,
      connected: false,
      server_url: url,
      connection_id: connection_id,
      channel: Channel.new(connection_id)
    }

    WebSockex.start_link(
      url_with_params,
      __MODULE__,
      state,
      name: __MODULE__,
      handle_initial_conn_failure: true,
      async: true
    )
  end

  # --- Public API ---

  @doc "Get the current connection status."
  def status do
    WebSockex.cast(__MODULE__, {:get_status, self()})

    receive do
      {:connection_status, status} -> status
    after
      5_000 -> :unknown
    end
  end

  @doc "Update worker metadata on the server."
  def update_metadata(metadata) when is_map(metadata) do
    WebSockex.cast(__MODULE__, {:update_metadata, metadata})
  end

  # --- WebSockex Callbacks ---

  @impl true
  def handle_connect(_conn, state) do
    Logger.info("[PyreClient] Connected to #{state.server_url}")

    # Start both keepalive timers
    ping_timer = schedule_ping()
    heartbeat_timer = schedule_heartbeat()

    state = %{state |
      connected: true,
      pong_received: true,
      ping_timer: ping_timer,
      heartbeat_timer: heartbeat_timer,
      pending_heartbeat_ref: nil
    }

    # Join channel after connection
    {frames, channel} = Channel.on_connected(state.channel)
    state = %{state | channel: channel}

    # Send all join frames
    case frames do
      [] -> {:ok, state}
      [frame] -> {:reply, frame, state}
      [frame | rest] ->
        # WebSockex only supports one reply frame at a time.
        # Send remaining frames via self-cast.
        for f <- rest, do: WebSockex.cast(self(), {:send_frame, f})
        {:reply, frame, state}
    end
  end

  @impl true
  def handle_disconnect(%{reason: reason, attempt_number: attempt}, state) do
    Logger.warning("[PyreClient] Disconnected: #{inspect(reason)} (attempt #{attempt})")

    # Cancel timers
    cancel_timer(state.ping_timer)
    cancel_timer(state.heartbeat_timer)

    # Notify channel layer
    channel = Channel.on_disconnected(state.channel)

    backoff = min(attempt * 1_000, 30_000)
    Logger.info("[PyreClient] Reconnecting in #{backoff}ms...")
    Process.sleep(backoff)

    {:reconnect, %{state |
      connected: false,
      pong_received: true,
      ping_timer: nil,
      heartbeat_timer: nil,
      pending_heartbeat_ref: nil,
      channel: channel
    }}
  end

  @impl true
  def handle_frame({:text, raw}, state) do
    case Protocol.decode(raw) do
      {:ok, %Message{} = msg} ->
        handle_phoenix_message(msg, state)

      {:error, reason} ->
        Logger.warning("[PyreClient] Failed to decode message: #{inspect(reason)}")
        {:ok, state}
    end
  end

  def handle_frame(_other, state) do
    {:ok, state}
  end

  @impl true
  def handle_pong(_frame, %{connected: false} = state), do: {:ok, state}
  def handle_pong(_frame, state) do
    {:ok, %{state | pong_received: true}}
  end

  @impl true
  def handle_cast({:send_frame, frame}, state) do
    {:reply, frame, state}
  end

  def handle_cast({:get_status, caller}, state) do
    send(caller, {:connection_status, %{
      connected: state.connected,
      connection_id: state.connection_id,
      channel: Channel.status(state.channel)
    }})
    {:ok, state}
  end

  def handle_cast({:update_metadata, metadata}, state) do
    {frames, channel} = Channel.send_update_metadata(state.channel, metadata)
    state = %{state | channel: channel}
    send_frames(frames, state)
  end

  def handle_cast({:send_event, event, payload}, state) do
    {frames, channel} = Channel.send_event(state.channel, event, payload)
    state = %{state | channel: channel}
    send_frames(frames, state)
  end

  @impl true
  def handle_info(:ws_ping, state) do
    case state do
      %{pong_received: true} ->
        timer = schedule_ping()
        {:reply, {:ping, ""}, %{state | pong_received: false, ping_timer: timer}}

      %{pong_received: false} ->
        Logger.warning("[PyreClient] No pong received, closing connection")
        {:close, state}
    end
  end

  def handle_info(:phoenix_heartbeat, state) do
    ref = Protocol.next_ref()
    msg = Protocol.heartbeat(ref)

    case Protocol.encode(msg) do
      {:ok, json} ->
        timer = schedule_heartbeat()
        {:reply, {:text, json}, %{state |
          heartbeat_timer: timer,
          pending_heartbeat_ref: ref
        }}

      {:error, reason} ->
        Logger.error("[PyreClient] Failed to encode heartbeat: #{inspect(reason)}")
        {:ok, state}
    end
  end

  # Forward any other messages to Channel (e.g., task completion notifications)
  def handle_info(msg, state) do
    case Channel.handle_info(msg, state.channel) do
      {frames, channel} ->
        state = %{state | channel: channel}
        send_frames(frames, state)
    end
  end

  # --- Phoenix Message Routing ---

  defp handle_phoenix_message(%Message{topic: "phoenix", event: "phx_reply"} = msg, state) do
    # Heartbeat reply
    if msg.ref == state.pending_heartbeat_ref do
      {:ok, %{state | pending_heartbeat_ref: nil}}
    else
      {:ok, state}
    end
  end

  defp handle_phoenix_message(%Message{} = msg, state) do
    # Delegate all channel messages
    {frames, channel} = Channel.handle_message(msg, state.channel)
    state = %{state | channel: channel}
    send_frames(frames, state)
  end

  # --- Helpers ---

  defp send_frames([], state), do: {:ok, state}
  defp send_frames([frame], state), do: {:reply, frame, state}
  defp send_frames([frame | rest], state) do
    for f <- rest, do: WebSockex.cast(self(), {:send_frame, f})
    {:reply, frame, state}
  end

  defp schedule_ping do
    Process.send_after(self(), :ws_ping, PyreClient.Config.ping_interval_ms())
  end

  defp schedule_heartbeat do
    Process.send_after(self(), :phoenix_heartbeat, PyreClient.Config.heartbeat_interval_ms())
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)

  defp append_params(url, params) do
    uri = URI.parse(url)
    existing = URI.decode_query(uri.query || "")
    merged = Map.merge(existing, params)
    %{uri | query: URI.encode_query(merged)} |> URI.to_string()
  end
end
```

## Key Design Decisions

### 1. `handle_initial_conn_failure: true`

Without this, if the server is down when the client starts, `start_link` returns `{:error, ...}` and the supervisor restarts the whole process. With it, the initial failure routes through `handle_disconnect`, giving us graceful backoff without supervisor churn.

### 2. `async: true`

Prevents blocking the supervision tree during connection. The process starts immediately and connects in the background.

### 3. Linear Backoff with Cap

```elixir
backoff = min(attempt * 1_000, 30_000)
```

Attempt 1 = 1s, attempt 2 = 2s, ... capped at 30s. Simple and predictable. We could make this exponential, but for a persistent worker connection, linear is fine — we always want to reconnect, and 30s max is reasonable.

### 4. Single-Frame Reply Limitation

WebSockex callbacks can only return one `{:reply, frame, state}`. When we need to send multiple frames (e.g., join + heartbeat), we send the first as the reply and self-cast the rest. The `{:send_frame, frame}` cast handler relays them.

### 5. Timer Cleanup on Disconnect

Both timers are cancelled in `handle_disconnect` and restarted in `handle_connect`. This prevents stale timer messages from arriving during reconnection.

## Connection Lifecycle

```
start_link
  │
  ├─→ [connect succeeds]
  │     handle_connect
  │       ├─ schedule WS ping timer (20s)
  │       ├─ schedule Phoenix heartbeat timer (30s)
  │       └─ Channel.on_connected → sends phx_join
  │
  │     [running]
  │       ├─ :ws_ping → send {:ping, ""}, check pong_received
  │       ├─ :phoenix_heartbeat → send heartbeat message
  │       ├─ handle_frame → decode, route to Channel
  │       └─ handle_pong → set pong_received = true
  │
  │     [connection lost]
  │       handle_disconnect
  │         ├─ cancel timers
  │         ├─ Channel.on_disconnected
  │         ├─ backoff sleep
  │         └─ {:reconnect, state}
  │              └─→ [loops back to handle_connect]
  │
  └─→ [connect fails]
        handle_disconnect (attempt 1)
          └─→ {:reconnect, state}
```
