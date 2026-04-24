defmodule PyreClient.Actions.Reserve do
  @moduledoc """
  Capacity reservation for workflow execution.

  Unlike other actions, Reserve doesn't perform LLM calls. It immediately
  acknowledges the reservation, then holds its capacity slot until the
  server sends `action_finish` when the workflow completes.

  The Runner handles Reserve's lifecycle directly — `execute/2` is not
  called through the normal LLM → action pipeline.
  """

  @behaviour PyreClient.Actions

  @impl true
  def execute(_payload, _context) do
    # Not called — Runner handles reserve lifecycle directly.
    {:ok, %{}}
  end
end
