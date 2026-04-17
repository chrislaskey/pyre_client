# Stage 3 — Phoenix Channel V2 Wire Protocol

## Overview

This is a pure encoding/decoding layer with no side effects. It handles the translation between Elixir terms and the JSON wire format that Phoenix channels expect. This module has no dependencies on WebSockex, GenServer, or any process state.

## Phoenix V2 Wire Format

All messages are JSON arrays with 5 elements:

```
[join_ref, ref, topic, event, payload]
```

| Field | Type | Description |
|-------|------|-------------|
| `join_ref` | `string \| null` | Links messages to a channel join session |
| `ref` | `string \| null` | Unique message ID for request/reply correlation |
| `topic` | `string` | Channel topic (e.g., `"pyre:connections"`, `"phoenix"`) |
| `event` | `string` | Event name (e.g., `"phx_join"`, `"heartbeat"`, custom) |
| `payload` | `map` | Message data |

## Special Events

| Event | Direction | Meaning |
|-------|-----------|---------|
| `phx_join` | client → server | Join a channel topic |
| `phx_leave` | client → server | Leave a channel topic |
| `phx_reply` | server → client | Reply to a client message |
| `phx_close` | server → client | Server closed the channel |
| `phx_error` | server → client | Channel crashed server-side |
| `heartbeat` | client → server | Keepalive (topic must be `"phoenix"`) |

## Module: `PyreClient.Protocol`

```elixir
defmodule PyreClient.Protocol do
  @moduledoc """
  Phoenix Channel V2 JSON wire protocol encoder/decoder.

  Handles the translation between Elixir message structs and the
  JSON array format used by Phoenix channels over WebSocket.
  """

  defmodule Message do
    @moduledoc "A decoded Phoenix Channel message."
    defstruct [:join_ref, :ref, :topic, :event, :payload]

    @type t :: %__MODULE__{
            join_ref: String.t() | nil,
            ref: String.t() | nil,
            topic: String.t(),
            event: String.t(),
            payload: map()
          }
  end

  @doc """
  Encode a Message struct to a JSON string for sending over WebSocket.

  ## Examples

      iex> PyreClient.Protocol.encode(%Message{
      ...>   join_ref: "1", ref: "2", topic: "pyre:connections",
      ...>   event: "action_output", payload: %{"line" => "hello"}
      ...> })
      {:ok, ~s(["1","2","pyre:connections","action_output",{"line":"hello"}])}
  """
  @spec encode(Message.t()) :: {:ok, String.t()} | {:error, term()}
  def encode(%Message{} = msg) do
    Jason.encode([msg.join_ref, msg.ref, msg.topic, msg.event, msg.payload || %{}])
  end

  @doc """
  Decode a JSON string from the WebSocket into a Message struct.

  ## Examples

      iex> PyreClient.Protocol.decode(~s([null,"3","phoenix","phx_reply",{"status":"ok","response":{}}]))
      {:ok, %Message{join_ref: nil, ref: "3", topic: "phoenix", event: "phx_reply", payload: %{"status" => "ok", "response" => %{}}}}
  """
  @spec decode(String.t()) :: {:ok, Message.t()} | {:error, term()}
  def decode(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, [join_ref, ref, topic, event, payload]}
      when is_binary(topic) and is_binary(event) and is_map(payload) ->
        {:ok,
         %Message{
           join_ref: join_ref,
           ref: ref,
           topic: topic,
           event: event,
           payload: payload
         }}

      {:ok, other} ->
        {:error, {:invalid_message_format, other}}

      {:error, _} = error ->
        error
    end
  end

  # --- Message Constructors ---

  @doc "Build a heartbeat message."
  @spec heartbeat(String.t()) :: Message.t()
  def heartbeat(ref) do
    %Message{join_ref: nil, ref: ref, topic: "phoenix", event: "heartbeat", payload: %{}}
  end

  @doc "Build a channel join message."
  @spec join(String.t(), String.t(), map()) :: Message.t()
  def join(topic, join_ref, payload \\ %{}) do
    %Message{join_ref: join_ref, ref: join_ref, topic: topic, event: "phx_join", payload: payload}
  end

  @doc "Build a channel leave message."
  @spec leave(String.t(), String.t(), String.t()) :: Message.t()
  def leave(topic, join_ref, ref) do
    %Message{join_ref: join_ref, ref: ref, topic: topic, event: "phx_leave", payload: %{}}
  end

  @doc "Build an outgoing event message on a joined channel."
  @spec push(String.t(), String.t(), String.t(), String.t(), map()) :: Message.t()
  def push(topic, join_ref, ref, event, payload) do
    %Message{join_ref: join_ref, ref: ref, topic: topic, event: event, payload: payload}
  end

  # --- Reply Helpers ---

  @doc "Check if a message is a reply to a specific ref."
  @spec reply_to?(Message.t(), String.t()) :: boolean()
  def reply_to?(%Message{event: "phx_reply", ref: ref}, expected_ref), do: ref == expected_ref
  def reply_to?(_, _), do: false

  @doc "Check if a reply was successful."
  @spec ok_reply?(Message.t()) :: boolean()
  def ok_reply?(%Message{event: "phx_reply", payload: %{"status" => "ok"}}), do: true
  def ok_reply?(_), do: false

  @doc "Extract the response payload from a reply."
  @spec reply_response(Message.t()) :: map()
  def reply_response(%Message{event: "phx_reply", payload: %{"response" => resp}}), do: resp
  def reply_response(_), do: %{}

  # --- Ref Generation ---

  @doc "Generate a unique ref string. Uses a monotonic counter per process."
  @spec next_ref() :: String.t()
  def next_ref do
    counter = Process.get(:phoenix_ref_counter, 0) + 1
    Process.put(:phoenix_ref_counter, counter)
    Integer.to_string(counter)
  end
end
```

## Design Notes

1. **Pure functions only** — No GenServer, no side effects (except `next_ref/0` which uses process dictionary for simplicity, same pattern as Phoenix.js client).

2. **Struct-based messages** — Using `Message` structs instead of raw tuples/maps gives us pattern matching, documentation, and compile-time field checks.

3. **Ref management** — Refs are simple incrementing integers cast to strings. The Phoenix server doesn't care about the format, only that they're unique per connection. Process dictionary is fine here because refs are scoped to the WebSockex process.

4. **No binary protocol** — We only implement JSON text encoding. Binary protocol is an optimization that's unnecessary for our message volumes (workflow dispatch is low-frequency).

## Testability

This module is trivially testable — pure input/output functions:

```elixir
test "round-trips a message" do
  msg = Protocol.join("pyre:connections", "1", %{"status" => "active"})
  assert {:ok, encoded} = Protocol.encode(msg)
  assert {:ok, decoded} = Protocol.decode(encoded)
  assert decoded.topic == "pyre:connections"
  assert decoded.event == "phx_join"
  assert decoded.payload == %{"status" => "active"}
end

test "decodes a server reply" do
  raw = ~s([null,"3","phoenix","phx_reply",{"status":"ok","response":{}}])
  assert {:ok, msg} = Protocol.decode(raw)
  assert Protocol.ok_reply?(msg)
end
```
