defmodule PyreClient.LLM.ClaudeCLITest do
  use ExUnit.Case, async: false

  alias PyreClient.LLM.ClaudeCLI

  setup do
    original = Application.get_env(:pyre_client, :claude_cli_executable)
    Application.put_env(:pyre_client, :claude_cli_executable, "echo")

    on_exit(fn ->
      if original do
        Application.put_env(:pyre_client, :claude_cli_executable, original)
      else
        Application.delete_env(:pyre_client, :claude_cli_executable)
      end
    end)

    :ok
  end

  test "manages_tool_loop? returns true" do
    assert ClaudeCLI.manages_tool_loop?() == true
  end

  test "map_model maps standard model names" do
    assert ClaudeCLI.map_model("anthropic:claude-sonnet-4-20250514") == "sonnet"
    assert ClaudeCLI.map_model("anthropic:claude-opus-4-20250514") == "opus"
    assert ClaudeCLI.map_model("anthropic:claude-haiku-4-5") == "haiku"
    assert ClaudeCLI.map_model("sonnet") == "sonnet"
    assert ClaudeCLI.map_model("custom-model") == "custom-model"
  end

  test "extract_prompts separates system and user messages" do
    messages = [
      %{role: :system, content: "You are a helper"},
      %{role: :user, content: "Do something"}
    ]

    {system, user} = ClaudeCLI.extract_prompts(messages)
    assert system == "You are a helper"
    assert String.contains?(user, "Do something")
    assert String.contains?(user, "<persona>")
  end

  test "extract_prompts with no system message" do
    messages = [%{role: :user, content: "Just a question"}]

    {system, user} = ClaudeCLI.extract_prompts(messages)
    assert system == ""
    assert user == "Just a question"
  end

  test "extract_prompts with multiple user messages" do
    messages = [
      %{role: :user, content: "First message"},
      %{role: :user, content: "Second message"}
    ]

    {_system, user} = ClaudeCLI.extract_prompts(messages)
    assert String.contains?(user, "First message")
    assert String.contains?(user, "Second message")
  end
end
