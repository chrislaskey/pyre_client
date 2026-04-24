defmodule PyreClient.Session.Registry do
  @moduledoc """
  Maps Pyre-generated session IDs to backend-specific session IDs.

  Backends like Cursor CLI generate their own session IDs internally — the
  caller can't pre-specify them. This registry stores the mapping so that
  Pyre's pre-allocated UUIDs can be translated to the real backend session
  ID on resume calls.
  """

  use Agent

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [[]]},
      restart: :permanent,
      type: :worker
    }
  end

  def start_link(_opts) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @doc """
  Looks up the backend session ID for the given Pyre session ID.

  Returns `nil` if no mapping exists.
  """
  @spec get(String.t()) :: String.t() | nil
  def get(pyre_session_id) do
    Agent.get(__MODULE__, &Map.get(&1, pyre_session_id))
  end

  @doc """
  Stores a mapping from Pyre session ID to backend session ID.
  """
  @spec put(String.t(), String.t()) :: :ok
  def put(pyre_session_id, backend_session_id) do
    Agent.update(__MODULE__, &Map.put(&1, pyre_session_id, backend_session_id))
  end
end
