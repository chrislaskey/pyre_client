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
  """
  @spec encode(Message.t()) :: {:ok, String.t()} | {:error, term()}
  def encode(%Message{} = msg) do
    Jason.encode([msg.join_ref, msg.ref, msg.topic, msg.event, msg.payload || %{}])
  end

  @doc """
  Decode a JSON string from the WebSocket into a Message struct.
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
    %Message{
      join_ref: join_ref,
      ref: join_ref,
      topic: topic,
      event: "phx_join",
      payload: payload
    }
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
