defmodule PyreClient.Actions.GitReview do
  @moduledoc """
  LLM -> parse verdict -> git (fire-and-forget) -> GitHub comment.

  Error policy: git/GitHub are fire-and-forget; action succeeds if LLM succeeds.
  If approved, also marks the PR as ready for review.
  """

  @behaviour PyreClient.Actions

  alias PyreClient.Actions.{Git, GitHub}

  require Logger

  @impl true
  def execute(payload, context) do
    inner = payload["payload"] || %{}
    working_dir = inner["working_dir"]
    pr_number = inner["pr_number"]
    github_config = inner["github"]

    Logger.info("[Actions.GitReview] #{context.execution_id}: starting")

    case PyreClient.Actions.LLM.call(context) do
      {:ok, text} ->
        verdict = Git.parse_verdict(text)

        # Git operations — fire and forget
        try do
          Git.add_all(working_dir)
          Git.commit("Code review changes", working_dir)
          Git.push_current_branch(working_dir)
        rescue
          e -> Logger.warning("[Actions.GitReview] Git ops failed (non-fatal): #{inspect(e)}")
        end

        # GitHub operations — fire and forget
        if github_config do
          try do
            GitHub.create_comment(github_config, pr_number, text)

            if verdict == "approve" do
              GitHub.mark_ready_for_review(github_config, pr_number)
            end
          rescue
            e ->
              Logger.warning("[Actions.GitReview] GitHub ops failed (non-fatal): #{inspect(e)}")
          end
        end

        {:ok, %{"text" => text, "verdict" => verdict}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
