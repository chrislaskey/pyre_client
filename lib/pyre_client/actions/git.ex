defmodule PyreClient.Actions.Git do
  @moduledoc """
  Shared git operations and LLM response parsing for git action types.
  """

  require Logger

  # --- Response Parsing ---

  @doc """
  Parse a shipping plan from LLM response text.

  Extracts: branch_name, commit_message, pr_title, pr_body.
  Returns {:ok, plan} or {:error, :parse_failed}.
  """
  def parse_shipping_plan(text) do
    with {:ok, branch} <- extract_field(text, "branch_name"),
         {:ok, commit_msg} <- extract_field(text, "commit_message"),
         {:ok, pr_title} <- extract_field(text, "pr_title"),
         {:ok, pr_body} <- extract_field(text, "pr_body") do
      {:ok,
       %{
         branch_name: branch,
         commit_message: commit_msg,
         pr_title: pr_title,
         pr_body: pr_body
       }}
    else
      _ -> {:error, :parse_failed}
    end
  end

  @doc """
  Parse an APPROVE/REJECT verdict from LLM review text.

  Returns "approve", "reject", or "unknown".
  """
  def parse_verdict(text) do
    text
    |> String.split("\n")
    |> Enum.reduce("unknown", fn line, acc ->
      cond do
        String.contains?(String.upcase(line), "APPROVE") -> "approve"
        String.contains?(String.upcase(line), "REJECT") -> "reject"
        true -> acc
      end
    end)
  end

  # --- Git Operations ---

  def edit_gitignore(working_dir) do
    gitignore_path = Path.join(working_dir, ".gitignore")

    if File.exists?(gitignore_path) do
      content = File.read!(gitignore_path)

      updated =
        content
        |> String.split("\n")
        |> Enum.reject(&String.contains?(&1, "priv/pyre/features/"))
        |> Enum.reject(&String.contains?(&1, "priv/pyre/runs/"))
        |> Enum.join("\n")

      File.write!(gitignore_path, updated)
    end

    :ok
  end

  def checkout_or_create_branch(branch_name, working_dir) do
    case run_git(["checkout", "-b", branch_name], working_dir) do
      :ok ->
        {:ok, branch_name}

      {:error, _} ->
        # Branch already exists, switch to it
        case run_git(["checkout", branch_name], working_dir) do
          :ok -> {:ok, branch_name}
          error -> error
        end
    end
  end

  def checkout_branch(branch_name, working_dir) do
    case run_git(["checkout", "-b", branch_name], working_dir) do
      :ok -> {:ok, branch_name}
      error -> error
    end
  end

  def add_all(working_dir) do
    run_git(["add", "-A"], working_dir)
  end

  def commit(message, working_dir) do
    case run_git(["commit", "-m", message], working_dir) do
      :ok ->
        :ok

      {:error, output} ->
        if String.contains?(to_string(output), "nothing to commit") do
          :ok
        else
          {:error, output}
        end
    end
  end

  def push(branch_name, working_dir) do
    run_git(["push", "-u", "origin", branch_name], working_dir)
  end

  def push_current_branch(working_dir) do
    case run_git_output(["rev-parse", "--abbrev-ref", "HEAD"], working_dir) do
      {:ok, branch} -> run_git(["push", "origin", String.trim(branch)], working_dir)
      error -> error
    end
  end

  # --- Helpers ---

  defp run_git(args, working_dir) do
    case System.cmd("git", args, cd: working_dir, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, _code} -> {:error, output}
    end
  end

  defp run_git_output(args, working_dir) do
    case System.cmd("git", args, cd: working_dir, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _code} -> {:error, output}
    end
  end

  defp extract_field(text, field_name) do
    case Regex.run(~r/#{field_name}:\s*(.+)/i, text) do
      [_, value] -> {:ok, String.trim(value)}
      _ -> {:error, "#{field_name} not found"}
    end
  end
end
