defmodule PyreClient.LLM.MockTest do
  use ExUnit.Case, async: false

  alias PyreClient.LLM.Mock

  test "generate/3 returns mock response from process dictionary" do
    Process.put(:mock_llm_responses, ["hello world"])
    assert {:ok, "hello world"} = Mock.generate("standard", [%{role: :user, content: "hi"}], [])
  end

  test "generate/3 consumes responses in order" do
    Process.put(:mock_llm_responses, ["first", "second"])

    assert {:ok, "first"} = Mock.generate("standard", [%{role: :user, content: "1"}], [])
    assert {:ok, "second"} = Mock.generate("standard", [%{role: :user, content: "2"}], [])
  end

  test "generate/3 returns default when queue is exhausted" do
    Process.put(:mock_llm_responses, [])

    assert {:ok, "Mock response (exhausted)"} =
             Mock.generate("standard", [%{role: :user, content: "hi"}], [])
  end

  test "generate/3 returns single mock_llm_response when queue not set" do
    Process.delete(:mock_llm_responses)
    Process.put(:mock_llm_response, "single response")

    assert {:ok, "single response"} =
             Mock.generate("standard", [%{role: :user, content: "hi"}], [])

    Process.delete(:mock_llm_response)
  end

  test "stream/3 delegates to generate (no streaming in mock)" do
    Process.put(:mock_llm_responses, ["streamed"])
    assert {:ok, "streamed"} = Mock.stream("standard", [%{role: :user, content: "hi"}], [])
  end

  test "chat/4 returns ReqLLM.Response struct" do
    Process.put(:mock_llm_responses, ["chatted"])

    assert {:ok, %ReqLLM.Response{}} =
             Mock.chat("standard", [%{role: :user, content: "hi"}], [], [])
  end

  test "manages_tool_loop? returns false" do
    refute Mock.manages_tool_loop?()
  end
end
