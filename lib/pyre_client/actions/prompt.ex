defmodule PyreClient.Actions.Prompt do
  @moduledoc """
  Generic LLM prompt execution.

  Covers: ProductManager, Designer, SoftwareArchitect, Programmer,
  TestWriter, SoftwareEngineer, PrototypeEngineer, Generalist, QAReviewer.

  For QAReviewer, the server parses the verdict from the returned text.
  """

  @behaviour PyreClient.Actions

  require Logger

  @impl true
  def execute(_payload, context) do
    Logger.info(
      "[Actions.Prompt] #{context.execution_id}: executing via #{inspect(context.backend)}"
    )

    case PyreClient.Actions.LLM.call(context) do
      {:ok, text} -> {:ok, %{"text" => text}}
      {:error, reason} -> {:error, reason}
    end
  end
end
