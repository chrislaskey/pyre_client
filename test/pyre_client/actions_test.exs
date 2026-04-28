defmodule PyreClient.ActionsTest do
  use ExUnit.Case, async: true

  alias PyreClient.Actions

  test "resolve returns correct modules for known action types" do
    assert {:ok, PyreClient.Actions.Prompt} = Actions.resolve("prompt")
    assert {:ok, PyreClient.Actions.GitPRSetup} = Actions.resolve("git_pr_setup")
    assert {:ok, PyreClient.Actions.GitShip} = Actions.resolve("git_ship")
    assert {:ok, PyreClient.Actions.GitReview} = Actions.resolve("git_review")
    assert {:ok, PyreClient.Actions.TestConnection} = Actions.resolve("test_connection")
  end

  test "resolve returns :error for unknown action types" do
    assert :error = Actions.resolve("unknown")
    assert :error = Actions.resolve("execute_commands")
  end

  test "list_actions returns all built-in action types" do
    actions = Actions.list_actions()
    names = Enum.map(actions, & &1.name)

    assert "prompt" in names
    assert "git_pr_setup" in names
    assert "git_ship" in names
    assert "git_review" in names
    assert "test_connection" in names
  end

  test "included_actions returns action metadata maps" do
    actions = PyreClient.Config.included_actions()

    assert Enum.all?(actions, fn a ->
             Map.has_key?(a, :module) and Map.has_key?(a, :name) and
               Map.has_key?(a, :label) and Map.has_key?(a, :description)
           end)
  end
end
