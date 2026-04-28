defmodule PyreClient.Actions.TestConnection do
  @moduledoc """
  Simple connection health check.

  Unlike other actions, TestConnection doesn't perform LLM calls. It
  immediately responds with a timestamp to confirm the client received
  the request and the round-trip communication is working.

  The Runner handles TestConnection's lifecycle directly — `execute/2`
  is not called through the normal LLM -> action pipeline.
  """

  @behaviour PyreClient.Actions

  @impl true
  def execute(_payload, _context) do
    {:ok, %{}}
  end
end
