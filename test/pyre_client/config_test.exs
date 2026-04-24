defmodule PyreClient.ConfigTest do
  use ExUnit.Case, async: false

  alias PyreClient.Config

  # --- Backend callbacks ---

  test "included_backends returns all built-in backends" do
    backends = Config.included_backends()
    names = Enum.map(backends, & &1.name)

    assert "req_llm" in names
    assert "claude_cli" in names
    assert "cursor_cli" in names
    assert "codex_cli" in names
  end

  test "default_backend returns configured backend" do
    original = Application.get_env(:pyre_client, :llm_backend)
    Application.put_env(:pyre_client, :llm_backend, :claude_cli)
    assert Config.default_backend() == PyreClient.LLM.ClaudeCLI

    if original do
      Application.put_env(:pyre_client, :llm_backend, original)
    else
      Application.delete_env(:pyre_client, :llm_backend)
    end
  end

  test "default_backend falls back to ReqLLM when not configured" do
    original = Application.get_env(:pyre_client, :llm_backend)
    Application.delete_env(:pyre_client, :llm_backend)
    assert Config.default_backend() == PyreClient.LLM.ReqLLM

    if original do
      Application.put_env(:pyre_client, :llm_backend, original)
    end
  end

  # --- Action callbacks ---

  test "included_actions returns all built-in action types" do
    actions = Config.included_actions()
    names = Enum.map(actions, & &1.name)

    assert "prompt" in names
    assert "git_pr_setup" in names
    assert "git_ship" in names
    assert "git_review" in names
  end

  test "resolve_action returns correct modules" do
    assert {:ok, PyreClient.Actions.Prompt} = Config.resolve_action("prompt")
    assert {:ok, PyreClient.Actions.GitPRSetup} = Config.resolve_action("git_pr_setup")
  end

  test "resolve_action returns :error for unknown types" do
    assert :error = Config.resolve_action("unknown")
  end

  # --- Model resolution ---

  test "resolve_model maps tier to model string" do
    assert Config.resolve_model("standard", nil) =~ "claude-sonnet"
    assert Config.resolve_model("fast", nil) =~ "haiku"
    assert Config.resolve_model("advanced", nil) =~ "opus"
  end

  test "resolve_model passes through unknown tiers" do
    assert Config.resolve_model("custom-model", nil) == "custom-model"
  end

  test "resolve_model handles nil tier" do
    result = Config.resolve_model(nil, nil)
    assert is_binary(result)
    assert result =~ "claude-sonnet"
  end

  # --- Static helpers ---

  test "server_url has a default" do
    assert is_binary(Config.server_url())
  end

  test "connection_id returns a string" do
    assert is_binary(Config.connection_id())
  end

  test "available_capacity defaults to 1" do
    original = Application.get_env(:pyre_client, :available_capacity)
    Application.delete_env(:pyre_client, :available_capacity)
    assert Config.available_capacity() == 1

    if original do
      Application.put_env(:pyre_client, :available_capacity, original)
    end
  end

  test "ping_interval_ms has a default" do
    assert is_integer(Config.ping_interval_ms())
  end

  test "heartbeat_interval_ms has a default" do
    assert is_integer(Config.heartbeat_interval_ms())
  end
end
