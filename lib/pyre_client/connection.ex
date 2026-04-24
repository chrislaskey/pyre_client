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

    # Append connection_id and vsn for Phoenix V2 wire protocol
    url_with_params = append_params(url, %{"connection_id" => connection_id, "vsn" => "2.0.0"})

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

    state = %{
      state
      | connected: true,
        pong_received: true,
        ping_timer: ping_timer,
        heartbeat_timer: heartbeat_timer,
        pending_heartbeat_ref: nil
    }

    # Join channel after connection
    {frames, channel} = Channel.on_connected(state.channel)
    state = %{state | channel: channel}

    # handle_connect can only return {:ok, state} — send frames via self-cast
    for frame <- frames, do: WebSockex.cast(self(), {:send_frame, frame})

    {:ok, state}
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

    {:reconnect,
     %{
       state
       | connected: false,
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
    send(
      caller,
      {:connection_status,
       %{
         connected: state.connected,
         connection_id: state.connection_id,
         channel: Channel.status(state.channel)
       }}
    )

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

        {:reply, {:text, json}, %{state | heartbeat_timer: timer, pending_heartbeat_ref: ref}}

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
