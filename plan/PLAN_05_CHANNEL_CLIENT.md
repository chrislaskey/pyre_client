# Stage 5 — Channel Client

## Overview

`PyreClient.Channel` manages the Phoenix channel state machine: joining topics, tracking join refs, handling replies, and translating between the worker's intent and protocol frames. It is a pure functional module — no process, no side effects. The `Connection` module calls into it and sends the resulting frames.

## Responsibilities

1. Join `pyre:connections` with worker metadata on connect
2. Track channel join state (joining → joined → left)
3. Handle `phx_reply` to join requests
4. Handle `action` pushes from the server (dispatch to Executor)
5. Handle `action_continue` pushes (forward to blocked execution process via Executor)
6. Handle `action_finish` pushes (signal execution to release via Executor)
7. Handle `presence_diff` events
8. Send `action_output`, `action_result`, `action_complete`, `update_metadata` messages

## Channel State

```elixir
defmodule PyreClient.Channel do
  @moduledoc """
  Phoenix channel state management.

  Pure functional module that tracks channel join state and produces
  protocol frames. Called by `PyreClient.Connection`.
  """

  alias PyreClient.Protocol
  alias PyreClient.Protocol.Message
  alias PyreClient.Executor

  require Logger

  defstruct [
    :connection_id,
    :join_ref,
    :status,        # :disconnected | :joining | :joined
    :pending_refs    # %{ref => callback_tag} for tracking request/reply
  ]

  @topic "pyre:connections"

  @type t :: %__MODULE__{}
  @type frame :: {:text, String.t()}
  @type frames_and_state :: {[frame()], t()}

  # --- Initialization ---

  @doc "Create a new channel state."
  @spec new(String.t()) :: t()
  def new(connection_id) do
    %__MODULE__{
      connection_id: connection_id,
      status: :disconnected,
      pending_refs: %{}
    }
  end

  @doc "Get the channel status."
  @spec status(t()) :: map()
  def status(%__MODULE__{} = ch) do
    %{
      topic: @topic,
      status: ch.status,
      connection_id: ch.connection_id
    }
  end

  # --- Lifecycle ---

  @doc """
  Called when the WebSocket connects (or reconnects).
  Sends the phx_join message for pyre:connections.
  """
  @spec on_connected(t()) :: frames_and_state()
  def on_connected(%__MODULE__{} = ch) do
    join_ref = Protocol.next_ref()

    payload = %{
      "connection_id" => ch.connection_id,
      "status" => "active",
      "available_capacity" => PyreClient.Config.available_capacity(),
      "backends" => PyreClient.LLM.Config.list_backends() |> Enum.map(& &1.name),
      "enabled_workflows" => PyreClient.Config.enabled_workflows(),
      "name" => PyreClient.Config.connection_name()
    }

    msg = Protocol.join(@topic, join_ref, payload)

    ch = %{ch |
      join_ref: join_ref,
      status: :joining,
      pending_refs: %{}
    }

    encode_and_return(msg, ch)
  end

  @doc "Called when the WebSocket disconnects."
  @spec on_disconnected(t()) :: t()
  def on_disconnected(%__MODULE__{} = ch) do
    # Notify worker of disconnection so it can clean up any in-flight executions
    Executor.on_disconnected()

    %{ch |
      status: :disconnected,
      join_ref: nil,
      pending_refs: %{}
    }
  end

  # --- Incoming Messages ---

  @doc "Handle a decoded Phoenix message. Returns frames to send and updated state."
  @spec handle_message(Message.t(), t()) :: frames_and_state()

  # Join reply
  def handle_message(
    %Message{topic: @topic, event: "phx_reply", ref: ref} = msg,
    %{status: :joining, join_ref: ref} = ch
  ) do
    if Protocol.ok_reply?(msg) do
      Logger.info("[PyreClient.Channel] Joined #{@topic}")
      {[], %{ch | status: :joined}}
    else
      Logger.error("[PyreClient.Channel] Join rejected: #{inspect(Protocol.reply_response(msg))}")
      {[], %{ch | status: :disconnected}}
    end
  end

  # Action dispatch from server
  def handle_message(
    %Message{topic: @topic, event: "action", payload: payload},
    %{status: :joined} = ch
  ) do
    Logger.info("[PyreClient.Channel] Received action: #{payload["type"]} (#{payload["execution_id"]})")

    # Delegate to executor — it will send frames back via Connection casts
    Executor.handle_action(payload)

    {[], ch}
  end

  # Interactive continuation — user replied, forward to blocked execution process
  def handle_message(
    %Message{topic: @topic, event: "action_continue", payload: payload},
    %{status: :joined} = ch
  ) do
    Logger.info("[PyreClient.Channel] Received action_continue: #{payload["execution_id"]}")
    Executor.handle_continue(payload)
    {[], ch}
  end

  # Interactive finish — release the blocked execution process
  def handle_message(
    %Message{topic: @topic, event: "action_finish", payload: payload},
    %{status: :joined} = ch
  ) do
    Logger.info("[PyreClient.Channel] Received action_finish: #{payload["execution_id"]}")
    Executor.handle_finish(payload)
    {[], ch}
  end

  # Presence diff
  def handle_message(
    %Message{topic: @topic, event: "presence_diff", payload: payload},
    ch
  ) do
    joins = Map.keys(payload["joins"] || %{})
    leaves = Map.keys(payload["leaves"] || %{})

    if joins != [] or leaves != [] do
      Logger.debug("[PyreClient.Channel] Presence: +#{length(joins)} -#{length(leaves)}")
    end

    {[], ch}
  end

  # Reply to a tracked request
  def handle_message(
    %Message{topic: @topic, event: "phx_reply", ref: ref} = msg,
    ch
  ) do
    case Map.pop(ch.pending_refs, ref) do
      {nil, _} ->
        {[], ch}

      {tag, pending_refs} ->
        Logger.debug("[PyreClient.Channel] Reply for #{tag}: #{inspect(Protocol.reply_response(msg))}")
        {[], %{ch | pending_refs: pending_refs}}
    end
  end

  # Server closed channel
  def handle_message(%Message{topic: @topic, event: "phx_close"}, ch) do
    Logger.warning("[PyreClient.Channel] Server closed channel")
    {[], %{ch | status: :disconnected}}
  end

  # Server error
  def handle_message(%Message{topic: @topic, event: "phx_error"}, ch) do
    Logger.error("[PyreClient.Channel] Server channel error")
    {[], %{ch | status: :disconnected}}
  end

  # Unhandled
  def handle_message(%Message{} = msg, ch) do
    Logger.debug("[PyreClient.Channel] Unhandled: #{msg.topic}:#{msg.event}")
    {[], ch}
  end

  # --- Outgoing Messages ---

  @doc "Send an update_metadata event."
  @spec send_update_metadata(t(), map()) :: frames_and_state()
  def send_update_metadata(%{status: :joined} = ch, metadata) do
    ref = Protocol.next_ref()
    msg = Protocol.push(@topic, ch.join_ref, ref, "update_metadata", metadata)
    ch = %{ch | pending_refs: Map.put(ch.pending_refs, ref, :update_metadata)}
    encode_and_return(msg, ch)
  end

  def send_update_metadata(ch, _metadata) do
    Logger.warning("[PyreClient.Channel] Cannot update metadata: not joined")
    {[], ch}
  end

  @doc "Send an arbitrary event on the channel."
  @spec send_event(t(), String.t(), map()) :: frames_and_state()
  def send_event(%{status: :joined} = ch, event, payload) do
    ref = Protocol.next_ref()
    msg = Protocol.push(@topic, ch.join_ref, ref, event, payload)
    encode_and_return(msg, ch)
  end

  def send_event(ch, event, _payload) do
    Logger.warning("[PyreClient.Channel] Cannot send #{event}: not joined")
    {[], ch}
  end

  # --- Info Messages ---

  @doc "Handle process messages forwarded from Connection."
  @spec handle_info(term(), t()) :: frames_and_state()

  # Executor wants to send a message back to the server
  def handle_info({:worker_send, event, payload}, ch) do
    send_event(ch, event, payload)
  end

  def handle_info(_msg, ch) do
    {[], ch}
  end

  # --- Helpers ---

  defp encode_and_return(%Message{} = msg, ch) do
    case Protocol.encode(msg) do
      {:ok, json} -> {[{:text, json}], ch}
      {:error, reason} ->
        Logger.error("[PyreClient.Channel] Encode error: #{inspect(reason)}")
        {[], ch}
    end
  end
end
```

## State Machine

```
:disconnected ──[on_connected]──→ :joining ──[phx_reply ok]──→ :joined
       ▲                                │                          │
       │                    [phx_reply error]              [phx_close/error]
       │                                │                          │
       └────────────────────────────────┴──────────────────────────┘
                              │
                      [on_disconnected]
```

Messages are only processed in the `:joined` state. Join replies are only accepted in the `:joining` state. This prevents processing stale messages during reconnection.

## Join Payload

When joining `pyre:connections`, the client sends its full worker metadata:

```json
{
  "connection_id": "linux-worker-1",
  "status": "active",
  "available_capacity": 1,
  "backends": ["claude_cli"],
  "enabled_workflows": [],
  "name": "build-server-east"
}
```

This metadata is tracked by `PyreWeb.Presence` and read by host-app worker selectors (e.g., pyre_app's `QueueManager` and `WorkflowJob`) for dispatch routing.

## How the Executor Sends Messages

The Executor module runs commands in a spawned process. It sends messages back to the server by casting to the Connection process:

```elixir
# Inside Executor, running in a spawned process:
WebSockex.cast(PyreClient.Connection, {:send_event, "action_output", %{
  "execution_id" => execution_id,
  "line" => "cloning repository..."
}})
```

The Connection receives the cast, calls `Channel.send_event/3`, and sends the resulting frame. This keeps the Channel module pure — it never touches the WebSocket directly.
