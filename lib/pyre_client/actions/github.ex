defmodule PyreClient.Actions.GitHub do
  @moduledoc """
  Lightweight GitHub API client for git action types.

  Uses short-lived installation tokens provided per-request by the server.
  Three endpoints: create PR, create comment, mark ready for review.
  """

  require Logger

  @github_api "https://api.github.com"

  @doc "Create a pull request. Returns {:ok, %{url: url, number: number}} or {:error, reason}."
  def create_pull_request(github_config, plan, opts \\ []) do
    %{"owner" => owner, "repo" => repo, "token" => token} = github_config
    draft = Keyword.get(opts, :draft, false)

    body = %{
      title: plan.pr_title,
      body: plan.pr_body,
      head: plan.branch_name,
      base: "main",
      draft: draft
    }

    case github_request(:post, "/repos/#{owner}/#{repo}/pulls", body, token) do
      {:ok, %{status: status, body: resp}} when status in [200, 201] ->
        {:ok, %{url: resp["html_url"], number: resp["number"]}}

      {:ok, %{status: status, body: resp}} ->
        {:error, "GitHub API #{status}: #{inspect(resp)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Post a comment on a PR."
  def create_comment(github_config, pr_number, body_text) do
    %{"owner" => owner, "repo" => repo, "token" => token} = github_config
    body = %{body: body_text}

    case github_request(
           :post,
           "/repos/#{owner}/#{repo}/issues/#{pr_number}/comments",
           body,
           token
         ) do
      {:ok, %{status: status}} when status in [200, 201] -> :ok
      {:ok, %{status: status, body: resp}} -> {:error, "GitHub API #{status}: #{inspect(resp)}"}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Mark a PR as ready for review (remove draft status)."
  def mark_ready_for_review(github_config, pr_number) do
    %{"token" => token} = github_config

    # This uses the GraphQL API (REST doesn't support removing draft status)
    query = """
    mutation {
      markPullRequestReadyForReview(input: {pullRequestId: "#{pr_number}"}) {
        pullRequest { number }
      }
    }
    """

    case github_request(:post, "/graphql", %{query: query}, token) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: status, body: resp}} ->
        {:error, "GitHub GraphQL #{status}: #{inspect(resp)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp github_request(method, path, body, token) do
    Req.request(
      method: method,
      url: @github_api <> path,
      json: body,
      headers: [
        {"authorization", "Bearer #{token}"},
        {"accept", "application/vnd.github+json"},
        {"x-github-api-version", "2022-11-28"}
      ]
    )
  end
end
