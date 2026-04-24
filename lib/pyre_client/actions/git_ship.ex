defmodule PyreClient.Actions.GitShip do
  @moduledoc """
  LLM -> parse shipping plan -> git -> GitHub PR (non-draft).

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

    Logger.info("[Actions.GitShip] #{context.execution_id}: starting")

    with {:ok, text} <- PyreClient.Actions.LLM.call(context),
         {:ok, plan} <- Git.parse_shipping_plan(text),
         {:ok, _branch} <- Git.checkout_branch(plan.branch_name, working_dir),
         :ok <- Git.add_all(working_dir),
         :ok <- Git.commit(plan.commit_message, working_dir),
         :ok <- Git.push(plan.branch_name, working_dir),
         {:ok, _pr} <- GitHub.create_pull_request(github_config, plan, draft: false) do
      {:ok,
       %{
         "text" => text,
         "shipping_summary" => "Branch: #{plan.branch_name}, PR: #{plan.pr_title}"
       }}
    else
      {:error, reason} ->
        Logger.error("[Actions.GitShip] #{context.execution_id}: failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
