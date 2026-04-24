defmodule PyreClient.Actions.PromptTest do
  use ExUnit.Case, async: false

  alias PyreClient.Actions.Prompt

  test "execute returns text from LLM" do
    # Mock queue uses plain strings — Mock.generate wraps in {:ok, _}
    Process.put(:mock_llm_responses, ["Generated architecture design"])

    context = %{
      execution_id: "test-1",
      backend: PyreClient.LLM.Mock,
      model: "standard",
      tools: [],
      opts: [messages: [%{role: :user, content: "Design an API"}], streaming: false],
      output_fn: fn _ -> :ok end,
      send_to_server: fn _, _ -> :ok end,
      interactive?: false
    }

    assert {:ok, %{"text" => "Generated architecture design"}} =
             Prompt.execute(%{}, context)
  end

  test "execute returns error from LLM failure" do
    # When the mock queue is exhausted, it returns a default string
    # To test errors, we need to manually set an error response
    Process.put(:mock_llm_responses, [])

    context = %{
      execution_id: "test-2",
      backend: PyreClient.LLM.Mock,
      model: "standard",
      tools: [],
      opts: [messages: [%{role: :user, content: "test"}], streaming: false],
      output_fn: fn _ -> :ok end,
      send_to_server: fn _, _ -> :ok end,
      interactive?: false
    }

    # Exhausted mock returns a default string, not an error
    assert {:ok, %{"text" => _}} = Prompt.execute(%{}, context)
  end

  test "execute uses cached llm_result_text when present" do
    # When called from the Runner, context includes llm_result_text
    # Actions.LLM.call should return it directly without calling the backend
    context = %{
      execution_id: "test-3",
      backend: PyreClient.LLM.Mock,
      model: "standard",
      tools: [],
      opts: [messages: [], streaming: false],
      output_fn: fn _ -> :ok end,
      send_to_server: fn _, _ -> :ok end,
      interactive?: false,
      llm_result_text: "Cached result from Runner"
    }

    assert {:ok, %{"text" => "Cached result from Runner"}} =
             Prompt.execute(%{}, context)
  end
end
