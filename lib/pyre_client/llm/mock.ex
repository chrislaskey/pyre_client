defmodule PyreClient.LLM.Mock do
  @moduledoc """
  Mock LLM module for testing.

  Returns responses configured via `Process.put(:mock_llm_response, "...")`.
  For sequenced responses, use `Process.put(:mock_llm_responses, ["r1", "r2", ...])`.
  """

  use PyreClient.LLM

  @impl true
  def generate(_model, _messages, _opts \\ []) do
    {:ok, next_response()}
  end

  @impl true
  def stream(_model, _messages, _opts \\ []) do
    {:ok, next_response()}
  end

  @impl true
  def chat(_model, _messages, _tools, _opts \\ []) do
    text = next_response()

    response = %ReqLLM.Response{
      id: "mock_#{System.unique_integer([:positive])}",
      model: "mock",
      context: ReqLLM.Context.new(),
      finish_reason: :stop,
      message: %ReqLLM.Message{
        role: :assistant,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: text}]
      }
    }

    {:ok, response}
  end

  defp next_response do
    case Process.get(:mock_llm_responses) do
      [response | rest] ->
        Process.put(:mock_llm_responses, rest)
        response

      [] ->
        "Mock response (exhausted)"

      nil ->
        Process.get(:mock_llm_response, "Mock response")
    end
  end
end
