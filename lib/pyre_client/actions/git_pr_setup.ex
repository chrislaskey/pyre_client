defmodule PyreClient.Actions.GitPRSetup do
  @moduledoc """
  LLM -> parse shipping plan -> edit .gitignore -> git -> draft GitHub PR.

  Error policy: fail on any git error.
  """

  @behaviour PyreClient.Actions

  alias PyreClient.Actions.{Git, GitHub}

  require Logger

  @impl true
  def execute(payload, context) do
    inner = payload["payload"] || %{}
    working_dir = inner["working_dir"]
    github_config = inner["github"]

    Logger.info("[Actions.GitPRSetup] #{context.execution_id}: starting")

    with {:ok, text} <- PyreClient.Actions.LLM.call(context),
         {:ok, plan} <- Git.parse_shipping_plan(text),
         :ok <- Git.edit_gitignore(working_dir),
         {:ok, _branch} <- Git.checkout_or_create_branch(plan.branch_name, working_dir),
         :ok <- Git.add_all(working_dir),
         :ok <- Git.commit(plan.commit_message, working_dir),
         :ok <- Git.push(plan.branch_name, working_dir),
         {:ok, pr} <- GitHub.create_pull_request(github_config, plan, draft: true) do
      {:ok,
       %{
         "text" => text,
         "branch_name" => plan.branch_name,
         "pr_url" => pr.url,
         "pr_number" => pr.number
       }}
    else
      {:error, reason} ->
        Logger.error("[Actions.GitPRSetup] #{context.execution_id}: failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
