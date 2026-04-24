defmodule PyreClient.Actions.GitTest do
  use ExUnit.Case, async: true

  alias PyreClient.Actions.Git

  test "parse_verdict detects APPROVE" do
    text = """
    I've reviewed the code thoroughly.

    APPROVE - The implementation looks correct.
    """

    assert Git.parse_verdict(text) == "approve"
  end

  test "parse_verdict detects REJECT" do
    text = """
    Several issues found.

    REJECT - Missing error handling.
    """

    assert Git.parse_verdict(text) == "reject"
  end

  test "parse_verdict returns unknown for ambiguous text" do
    assert Git.parse_verdict("This code looks fine.") == "unknown"
  end

  test "parse_verdict is case-insensitive" do
    assert Git.parse_verdict("approve") == "approve"
    assert Git.parse_verdict("Approve") == "approve"
    assert Git.parse_verdict("REJECT") == "reject"
  end

  test "parse_shipping_plan extracts structured fields" do
    text = """
    branch_name: feature/add-auth
    commit_message: Add authentication module
    pr_title: Add user authentication
    pr_body: Implements JWT-based auth with login/logout endpoints.
    """

    assert {:ok, plan} = Git.parse_shipping_plan(text)
    assert plan.branch_name == "feature/add-auth"
    assert plan.commit_message == "Add authentication module"
    assert plan.pr_title == "Add user authentication"
    assert plan.pr_body == "Implements JWT-based auth with login/logout endpoints."
  end

  test "parse_shipping_plan returns error for missing fields" do
    assert {:error, :parse_failed} = Git.parse_shipping_plan("just some text")
  end

  test "parse_shipping_plan returns error for partial fields" do
    text = """
    branch_name: feature/test
    commit_message: Test commit
    """

    assert {:error, :parse_failed} = Git.parse_shipping_plan(text)
  end
end
