# Stage 6 — Executor and Action Modules

## Overview

`PyreClient.Executor` receives action dispatches from the Channel, routes them to the appropriate action module, manages capacity, and handles the interactive loop. Action modules own the full execution lifecycle for their action type.

The server sends **named action types** with data parameters. The client has hardcoded implementations for each type. The server never sends shell commands or arbitrary code — the client decides what to execute based on its action modules. This is a security requirement: if the server could send commands over WebSocket, anyone with WebSocket access could compromise the client machine.

The Executor has **no knowledge of workflows, stages, or orchestration**. It executes individual actions when triggered.

## Action Types

| Type | Client Module | What it does |
|------|---------------|-------------|
| `prompt` | `PyreClient.Actions.Prompt` | Call an LLM backend with optional tool execution. Return text. Covers 9 of 11 server-side actions. |
| `git_pr_setup` | `PyreClient.Actions.GitPRSetup` | LLM call → parse shipping plan → edit .gitignore → git checkout/add/commit/push → create draft GitHub PR. Return text + branch + PR info. |
| `git_ship` | `PyreClient.Actions.GitShip` | LLM call → parse shipping plan → git checkout/add/commit/push → create GitHub PR (non-draft). Return text + shipping summary. |
| `git_review` | `PyreClient.Actions.GitReview` | LLM call → parse verdict → git add/commit/push (fire-and-forget) → post GitHub PR comment → maybe mark ready-for-review. Return text + verdict. |

All action types share the same LLM infrastructure (backend resolution, model tier mapping, tool building, streaming). The git action types add post-LLM processing: response parsing, git operations, and GitHub API calls.

## Channel Events

### Client → Server

| Event | When | Payload |
|-------|------|---------|
| `action_output` | Streaming token/line during execution | `%{"execution_id" => id, "content" => text}` |
| `action_result` | LLM call finished, interactive stage awaiting continuation | `%{"execution_id" => id, "result_text" => text}` |
| `action_complete` | Execution fully done, capacity slot freed | `%{"execution_id" => id, "status" => "ok" | "error", "result" => result_map}` |

### Server → Client

| Event | When | Payload |
|-------|------|---------|
| `action` | Dispatch new action to worker | `%{"execution_id" => id, "action" => "prompt", "payload" => {...}}` |
| `action_continue` | User replied during interactive stage | `%{"execution_id" => id, "message" => text}` |
| `action_finish` | Interactive loop done, release the worker | `%{"execution_id" => id}` |

The distinction between `action_result` and `action_complete` is key:
- **`action_result`**: The LLM call is done but the execution stays alive. The capacity slot remains occupied. The spawned process blocks waiting for `action_continue` or `action_finish`.
- **`action_complete`**: The execution is fully done. The capacity slot is freed. The `result` field contains action-specific structured data (e.g., `%{"text" => "..."}` for prompt, `%{"text" => "...", "branch_name" => "...", "pr_url" => "..."}` for git_pr_setup).

Non-interactive executions skip `action_result` entirely and go straight to `action_complete`.

## Execution Flow

### Non-interactive (any action type)

```
Server pushes "action" event
  │
  ▼
Channel.handle_message → Executor.handle_action/1
  │
  ├─ 1. Route by action type
  │    Actions.resolve(payload["action"])
  │    → {:ok, PyreClient.Actions.Prompt}
  │
  ├─ 2. Spawn execution process
  │    action_module.execute(execution_id, payload, context)
  │      ├─ Resolve backend, model, tools (shared LLM infrastructure)
  │      ├─ Call LLM → stream "action_output"
  │      └─ Post-LLM processing (git, GitHub, etc. for git actions)
  │
  └─ 3. Send "action_complete"
       ├─ status ("ok" or "error")
       └─ result (action-specific map)
```

### Interactive (any action type)

```
Server pushes "action" event (interactive: true)
  │
  ▼
Executor.handle_action/1 → spawns execution process
  │
  ├─ 1. Action module runs initial LLM call
  │    ├─ Stream tokens → "action_output"
  │    └─ Collect result text
  │
  ├─ 2. Send "action_result" (NOT "action_complete")
  │    └─ Execution process stays alive, capacity slot occupied
  │
  ├─ 3. Block waiting for continuation message from Executor GenServer
  │    │
  │    ├─ Server receives user reply → pushes "action_continue"
  │    │    ├─ Channel routes to Executor.handle_continue/1
  │    │    ├─ Executor forwards message to blocked execution process
  │    │    └─ Execution process resumes CLI session (resume: session_id)
  │    │         ├─ Stream tokens → "action_output"
  │    │         ├─ Send "action_result" with new result
  │    │         └─ Block again...
  │    │
  │    └─ Server sends "action_finish"
  │         ├─ Channel routes to Executor.handle_finish/1
  │         ├─ Executor signals execution process
  │         ├─ Action module runs post-LLM processing (git, GitHub, etc.)
  │         └─ Execution process sends "action_complete" and exits
  │
  └─ 4. Capacity slot freed on "action_complete"
```

The interactive loop is always about the LLM portion. Post-LLM processing runs after the interactive loop completes (`action_finish` received). From the client's perspective, `action_continue` is always "resume the LLM session with this message" — whether it's a user reply or a finalize prompt. The server distinguishes between the two; the client doesn't need to.

---

## Module: `PyreClient.Actions` — Behaviour + Registry

```elixir
defmodule PyreClient.Actions do
  @moduledoc """
  Action behaviour and routing registry.

  Each action type has a dedicated module that implements the full
  execution lifecycle. The Executor routes to the correct module
  via `resolve/1`.

  ## Security Model

  The server sends named action types with data parameters — never
  shell commands or arbitrary code. Each action module is a hardcoded
  implementation that decides what to execute locally. This ensures
  the client machine cannot be compromised via WebSocket access.
  """

  @type execution_context :: %{
    execution_id: String.t(),
    backend: module(),
    model: String.t(),
    tools: [ReqLLM.Tool.t()],
    opts: keyword(),
    output_fn: (String.t() -> :ok),
    send_to_server: (String.t(), map() -> :ok),
    interactive?: boolean()
  }

  @doc """
  Execute the action. Returns `{:ok, result_map}` or `{:error, reason}`.

  The `result_map` is action-specific:
  - `prompt`: `%{"text" => "..."}`
  - `git_pr_setup`: `%{"text" => "...", "branch_name" => "...", "pr_url" => "...", "pr_number" => 42}`
  - `git_ship`: `%{"text" => "...", "shipping_summary" => "..."}`
  - `git_review`: `%{"text" => "...", "verdict" => "approve" | "reject"}`
  """
  @callback execute(payload :: map(), context :: execution_context()) ::
              {:ok, map()} | {:error, term()}

  # --- Routing Registry ---

  @doc "Resolve an action type string to its implementation module."
  @spec resolve(String.t()) :: {:ok, module()} | :error
  def resolve("prompt"), do: {:ok, PyreClient.Actions.Prompt}
  def resolve("git_pr_setup"), do: {:ok, PyreClient.Actions.GitPRSetup}
  def resolve("git_ship"), do: {:ok, PyreClient.Actions.GitShip}
  def resolve("git_review"), do: {:ok, PyreClient.Actions.GitReview}
  def resolve(_), do: :error
end
```

---

## Module: `PyreClient.Actions.Prompt`

Handles the `prompt` action type — a generic LLM call that covers 9 of 11 server-side actions. The server builds the full messages array — including the persona system prompt (loaded via `Pyre.Plugins.Persona`), user message with artifacts and workspace constraints, and any prior conversation context — and sends them in the action payload. The client passes these messages directly to the LLM backend and returns the result text. The client never loads persona files or constructs system prompts.

```elixir
defmodule PyreClient.Actions.Prompt do
  @moduledoc """
  Generic LLM prompt execution.

  Covers: ProductManager, Designer, SoftwareArchitect, Programmer,
  TestWriter, SoftwareEngineer, PrototypeEngineer, Generalist, QAReviewer.

  For QAReviewer, the server parses the verdict from the returned text.
  """

  @behaviour PyreClient.Actions

  require Logger

  @impl true
  def execute(payload, context) do
    Logger.info("[Actions.Prompt] #{context.execution_id}: executing via #{inspect(context.backend)}")

    result = call_llm(context)

    case result do
      {:ok, text} -> {:ok, %{"text" => text}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp call_llm(context) do
    PyreClient.Actions.LLM.call(context)
  end
end
```

---

## Module: `PyreClient.Actions.GitPRSetup`

Handles the `git_pr_setup` action type — LLM call followed by git operations and draft GitHub PR creation. Used by the PRSetup action in the Feature flow.

```elixir
defmodule PyreClient.Actions.GitPRSetup do
  @moduledoc """
  LLM → parse shipping plan → edit .gitignore → git → draft GitHub PR.

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
      {:ok, %{
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
```

---

## Module: `PyreClient.Actions.GitShip`

Handles the `git_ship` action type — LLM call (conditionally with tools) followed by git operations and GitHub PR creation (non-draft). Used by the Shipper action in the OvernightFeature flow.

```elixir
defmodule PyreClient.Actions.GitShip do
  @moduledoc """
  LLM → parse shipping plan → git → GitHub PR (non-draft).

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
      {:ok, %{
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
```

---

## Module: `PyreClient.Actions.GitReview`

Handles the `git_review` action type — LLM call, verdict parsing, then fire-and-forget git/GitHub operations. Used by the PRReviewer action in the CodeReview flow.

```elixir
defmodule PyreClient.Actions.GitReview do
  @moduledoc """
  LLM → parse verdict → git (fire-and-forget) → GitHub comment.

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
            e -> Logger.warning("[Actions.GitReview] GitHub ops failed (non-fatal): #{inspect(e)}")
          end
        end

        {:ok, %{"text" => text, "verdict" => verdict}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

---

## Module: `PyreClient.Actions.LLM` — Shared LLM Infrastructure

All action modules use this shared module for LLM calls. It encapsulates backend resolution, model tier mapping, tool building, and the `manages_tool_loop?` routing logic.

```elixir
defmodule PyreClient.Actions.LLM do
  @moduledoc """
  Shared LLM calling infrastructure for action modules.

  Routes based on backend capability (mirrors pyre_lib's Helpers.call_llm/4):
  - CLI backends (manages_tool_loop? = true): direct chat/4
  - ReqLLM (manages_tool_loop? = false): AgenticLoop
  - No tools + streaming: stream/3
  - No tools + no streaming: generate/3
  """

  @doc "Execute an LLM call using the context. Returns {:ok, text} or {:error, reason}."
  def call(%{backend: backend, model: model, tools: tools, opts: opts, output_fn: output_fn} = _context) do
    result =
      cond do
        tools != [] and manages_tool_loop?(backend) ->
          backend.chat(model, context_messages(opts), tools, Keyword.put(opts, :output_fn, output_fn))

        tools != [] ->
          log_fn = fn msg -> output_fn.(msg <> "\n") end
          PyreClient.Tools.AgenticLoop.run(backend, model, context_messages(opts), tools,
            streaming: Keyword.get(opts, :streaming, false),
            output_fn: output_fn,
            log_fn: log_fn,
            verbose: Keyword.get(opts, :verbose, false)
          )

        Keyword.get(opts, :streaming, true) ->
          backend.stream(model, context_messages(opts), Keyword.put(opts, :output_fn, output_fn))

        true ->
          backend.generate(model, context_messages(opts), opts)
      end

    case result do
      {:ok, text} when is_binary(text) -> {:ok, text}
      {:ok, response} when is_map(response) -> {:ok, extract_text(response)}
      {:error, _} = error -> error
    end
  end

  defp context_messages(opts), do: Keyword.get(opts, :messages, [])
  defp manages_tool_loop?(backend) do
    function_exported?(backend, :manages_tool_loop?, 0) and backend.manages_tool_loop?()
  end
  defp extract_text(response), do: inspect(response)
end
```

---

## Module: `PyreClient.Actions.Git` — Shared Git Utilities

Extracted from pyre_lib's `Pyre.Actions.Shipper` and `Pyre.Actions.QAReviewer`. Provides git operations and response parsing used by all three git action types.

```elixir
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
    # Implementation adapted from Pyre.Actions.Shipper.parse_shipping_plan/1
    # Scans LLM response for structured fields
    with {:ok, branch} <- extract_field(text, "branch_name"),
         {:ok, commit_msg} <- extract_field(text, "commit_message"),
         {:ok, pr_title} <- extract_field(text, "pr_title"),
         {:ok, pr_body} <- extract_field(text, "pr_body") do
      {:ok, %{
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
    # Implementation adapted from Pyre.Actions.QAReviewer.parse_verdict/1
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
      :ok -> {:ok, branch_name}
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
      :ok -> :ok
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
    case run_git(["rev-parse", "--abbrev-ref", "HEAD"], working_dir) do
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

  defp extract_field(text, field_name) do
    # Simple regex extraction — adapted from Shipper's parsing logic
    case Regex.run(~r/#{field_name}:\s*(.+)/i, text) do
      [_, value] -> {:ok, String.trim(value)}
      _ -> {:error, "#{field_name} not found"}
    end
  end
end
```

---

## Module: `PyreClient.Actions.GitHub` — Lightweight GitHub API Client

Uses `req` (already a transitive dep via `req_llm`) for 3 HTTP endpoints. The server sends a short-lived GitHub installation token per-request in the `github` field of the action payload.

```elixir
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

    case github_request(:post, "/repos/#{owner}/#{repo}/issues/#{pr_number}/comments", body, token) do
      {:ok, %{status: status}} when status in [200, 201] -> :ok
      {:ok, %{status: status, body: resp}} -> {:error, "GitHub API #{status}: #{inspect(resp)}"}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Mark a PR as ready for review (remove draft status)."
  def mark_ready_for_review(github_config, pr_number) do
    %{"owner" => owner, "repo" => repo, "token" => token} = github_config

    # This uses the GraphQL API (REST doesn't support removing draft status)
    query = """
    mutation {
      markPullRequestReadyForReview(input: {pullRequestId: "#{pr_number}"}) {
        pullRequest { number }
      }
    }
    """

    case github_request(:post, "/graphql", %{query: query}, token) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status, body: resp}} -> {:error, "GitHub GraphQL #{status}: #{inspect(resp)}"}
      {:error, reason} -> {:error, reason}
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
```

---

## Module: `PyreClient.Executor` — Updated

The Executor GenServer is unchanged in structure. The key change: `execute/3` routes through `PyreClient.Actions.resolve/1` instead of pattern-matching on `"execute_prompt"`. The interactive loop remains shared infrastructure in the Executor.

```elixir
defmodule PyreClient.Executor do
  @moduledoc """
  Receives action dispatches, routes to action modules, manages capacity.

  Routes actions through `PyreClient.Actions.resolve/1` to the appropriate
  implementation module. Handles the interactive loop (action_continue /
  action_finish) as shared infrastructure for all action types.

  Has no knowledge of workflows, stages, or orchestration.
  """

  use GenServer

  require Logger

  @name __MODULE__

  defstruct [
    :max_capacity,
    :active_executions  # %{execution_id => pid}
  ]

  @execution_timeout 86_400_000  # 24 hours — matches workflow-level timeout

  # --- Start ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  @impl true
  def init(_opts) do
    state = %__MODULE__{
      max_capacity: PyreClient.Config.available_capacity(),
      active_executions: %{}
    }

    {:ok, state}
  end

  # --- Public API ---

  @doc "Handle an action dispatch from the server."
  def handle_action(payload) do
    GenServer.cast(@name, {:handle_action, payload})
  end

  @doc "Called when the WebSocket disconnects."
  def on_disconnected do
    GenServer.cast(@name, :on_disconnected)
  end

  @doc "Forward an action_continue from the server to a blocked execution process."
  def handle_continue(payload) do
    GenServer.cast(@name, {:handle_continue, payload})
  end

  @doc "Forward an action_finish from the server to release an execution."
  def handle_finish(payload) do
    GenServer.cast(@name, {:handle_finish, payload})
  end

  # --- Callbacks ---

  @impl true
  def handle_cast({:handle_action, payload}, state) do
    execution_id = payload["execution_id"]
    action_type = payload["action"]

    if has_capacity?(state) do
      pid = spawn_execution(execution_id, action_type, payload)
      active = Map.put(state.active_executions, execution_id, pid)
      state = %{state | active_executions: active}
      update_server_capacity(state)
      {:noreply, state}
    else
      Logger.info("[PyreClient.Executor] At capacity, cannot execute #{execution_id}")
      {:noreply, state}
    end
  end

  def handle_cast(:on_disconnected, state) do
    Logger.warning("[PyreClient.Executor] Disconnected, #{map_size(state.active_executions)} executions still running")
    {:noreply, state}
  end

  def handle_cast({:handle_continue, payload}, state) do
    execution_id = payload["execution_id"]

    case Map.get(state.active_executions, execution_id) do
      nil ->
        Logger.warning("[PyreClient.Executor] action_continue for unknown execution #{execution_id}")
        {:noreply, state}

      pid ->
        send(pid, {:continue, payload})
        {:noreply, state}
    end
  end

  def handle_cast({:handle_finish, payload}, state) do
    execution_id = payload["execution_id"]

    case Map.get(state.active_executions, execution_id) do
      nil ->
        Logger.warning("[PyreClient.Executor] action_finish for unknown execution #{execution_id}")
        {:noreply, state}

      pid ->
        send(pid, :finish)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:execution_done, execution_id}, state) do
    active = Map.delete(state.active_executions, execution_id)
    state = %{state | active_executions: active}
    update_server_capacity(state)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    active =
      state.active_executions
      |> Enum.reject(fn {_id, p} -> p == pid end)
      |> Map.new()

    if map_size(active) != map_size(state.active_executions) do
      state = %{state | active_executions: active}
      update_server_capacity(state)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Execution Dispatch ---

  defp spawn_execution(execution_id, action_type, payload) do
    executor_pid = self()

    {pid, _ref} =
      spawn_monitor(fn ->
        execute(execution_id, action_type, payload)
        send(executor_pid, {:execution_done, execution_id})
      end)

    pid
  end

  defp execute(execution_id, action_type, payload) do
    case PyreClient.Actions.resolve(action_type) do
      {:ok, action_module} ->
        context = build_context(execution_id, payload)

        # Phase 1: LLM call (+ interactive loop if interactive)
        llm_result =
          if context.interactive? do
            execute_interactive(execution_id, context)
          else
            PyreClient.Actions.LLM.call(context)
          end

        # Phase 2: Action module processes the LLM result
        case llm_result do
          {:ok, _text} ->
            # Put the LLM result text into context for the action module
            context = Map.put(context, :llm_result_text, elem(llm_result, 1))

            case action_module.execute(payload, context) do
              {:ok, result} ->
                send_to_server("action_complete", %{
                  "execution_id" => execution_id,
                  "status" => "ok",
                  "result" => result
                })

              {:error, reason} ->
                Logger.error("[PyreClient.Executor] #{execution_id}: action error: #{inspect(reason)}")
                send_to_server("action_complete", %{
                  "execution_id" => execution_id,
                  "status" => "error",
                  "result" => %{"error" => inspect(reason)}
                })
            end

          {:error, reason} ->
            Logger.error("[PyreClient.Executor] #{execution_id}: LLM error: #{inspect(reason)}")
            send_to_server("action_complete", %{
              "execution_id" => execution_id,
              "status" => "error",
              "result" => %{"error" => inspect(reason)}
            })
        end

      :error ->
        Logger.warning("[PyreClient.Executor] #{execution_id}: unknown action type: #{action_type}")
        send_to_server("action_complete", %{
          "execution_id" => execution_id,
          "status" => "error",
          "result" => %{"error" => "Unknown action type: #{action_type}"}
        })
    end
  end

  # --- Interactive Loop ---

  defp execute_interactive(execution_id, context) do
    # Run initial LLM call
    case PyreClient.Actions.LLM.call(context) do
      {:ok, text} ->
        send_to_server("action_result", %{
          "execution_id" => execution_id,
          "result_text" => text
        })

        interactive_loop(execution_id, context, text)

      {:error, _} = error ->
        error
    end
  end

  defp interactive_loop(execution_id, context, last_text) do
    receive do
      {:continue, payload} ->
        user_message = payload["message"] || ""
        session_id = Keyword.get(context.opts, :session_id)

        Logger.info("[PyreClient.Executor] #{execution_id}: interactive continue (session: #{session_id})")

        messages = [%{role: :user, content: user_message}]
        resume_opts = Keyword.put(context.opts, :resume, session_id)
        resume_opts = Keyword.put(resume_opts, :output_fn, context.output_fn)
        resume_opts = Keyword.put(resume_opts, :messages, messages)
        resume_context = %{context | opts: resume_opts}

        case PyreClient.Actions.LLM.call(resume_context) do
          {:ok, text} ->
            send_to_server("action_result", %{
              "execution_id" => execution_id,
              "result_text" => text
            })

            interactive_loop(execution_id, context, text)

          {:error, reason} ->
            Logger.error("[PyreClient.Executor] #{execution_id}: interactive LLM error: #{inspect(reason)}")
            {:error, reason}
        end

      :finish ->
        Logger.info("[PyreClient.Executor] #{execution_id}: interactive finished")
        {:ok, last_text}

    after
      @execution_timeout ->
        Logger.error("[PyreClient.Executor] #{execution_id}: interactive loop timed out")
        {:error, :interactive_timeout}
    end
  end

  # --- Context Building ---

  defp build_context(execution_id, payload) do
    inner = payload["payload"] || %{}
    model_tier = inner["model_tier"] || "standard"
    role = inner["role"]
    working_dir = inner["working_dir"]
    allowed_paths = inner["allowed_paths"] || []
    allowed_commands = inner["allowed_commands"]
    opts_map = inner["opts"] || %{}

    # Messages arrive pre-built from the server, including the full persona
    # system prompt and user message with artifacts/context. The client
    # passes them directly to the LLM backend — no persona loading needed.
    messages = inner["messages"] || []

    # The server sets interactive: true|false authoritatively. This determines
    # whether the client sends action_result (stays alive) or action_complete
    # (frees capacity) after the initial LLM call.
    interactive? = inner["interactive"] == true

    # Session IDs are generated by the server (Pyre.Session.generate_for_stages/1)
    # and included in the payload. The client stores the mapping for CLI session
    # resumption during action_continue.
    session_id = get_in(opts_map, ["session_id"])

    backend = PyreClient.LLM.Config.default_backend()
    model = PyreClient.LLM.Config.resolve_model(model_tier, backend)

    messages = Enum.map(messages, fn msg ->
      %{role: String.to_existing_atom(msg["role"]), content: msg["content"]}
    end)

    tools = build_tools(role, working_dir, allowed_paths, allowed_commands)

    opts =
      opts_map
      |> Enum.map(fn {k, v} -> {String.to_existing_atom(k), v} end)
      |> Keyword.new()
      |> Keyword.put(:messages, messages)

    output_fn = fn token -> send_output(execution_id, token) end

    %{
      execution_id: execution_id,
      backend: backend,
      model: model,
      tools: tools,
      opts: opts,
      output_fn: output_fn,
      send_to_server: &send_to_server/2,
      interactive?: interactive?
    }
  end

  # --- Tool Building ---

  defp build_tools(nil, _working_dir, _allowed_paths, _allowed_commands), do: []
  defp build_tools(_role, nil, _allowed_paths, _allowed_commands), do: []

  defp build_tools(role, working_dir, allowed_paths, allowed_commands) do
    role_atom = String.to_existing_atom(role)
    tool_opts = [allowed_paths: allowed_paths]
    tool_opts = if allowed_commands, do: Keyword.put(tool_opts, :allowed_commands, allowed_commands), else: tool_opts

    PyreClient.Tools.for_role(role_atom, working_dir, tool_opts)
  rescue
    ArgumentError -> []
  end

  # --- Output Streaming ---

  defp send_output(execution_id, content) do
    send_to_server("action_output", %{
      "execution_id" => execution_id,
      "content" => content
    })
  end

  # --- Helpers ---

  defp has_capacity?(state) do
    map_size(state.active_executions) < state.max_capacity
  end

  defp current_available_capacity(state) do
    state.max_capacity - map_size(state.active_executions)
  end

  defp send_to_server(event, payload) do
    WebSockex.cast(PyreClient.Connection, {:send_event, event, payload})
  end

  defp update_server_capacity(state) do
    PyreClient.Connection.update_metadata(%{
      "available_capacity" => current_available_capacity(state)
    })
  end
end
```

---

## Key Design Decisions

### 1. Client owns action lifecycle (security)

The server sends action names and data parameters, never shell commands or arbitrary code. Each action type has a hardcoded client module that decides what to execute. This prevents WebSocket access from being exploited to compromise the client machine. The client is rich in capability (LLM backends, git, GitHub) but has no concept of workflows.

### 2. 4 action types cover all current needs

- `prompt` — 9 of 11 server actions (the 8 templates + QAReviewer)
- `git_pr_setup` — PRSetup action (Feature flow, mid-pipeline)
- `git_ship` — Shipper action (OvernightFeature flow, final stage)
- `git_review` — PRReviewer action (CodeReview flow, sole stage)

New action types are rare (3 in the entire current codebase) and require lockstep updates to both pyre_lib and pyre_client. The `prompt` type covers the common case without client changes.

### 3. `manages_tool_loop?` routing

The shared `Actions.LLM` module mirrors the routing logic from pyre_lib's `Helpers.call_llm/4`:
- **CLI backends** (`manages_tool_loop? = true`): direct chat/4 (CLI manages its own tool loop)
- **ReqLLM** (`manages_tool_loop? = false`): routes through `AgenticLoop` for multi-turn tool use

### 4. Server builds messages with personas

The server loads persona files (`Pyre.Plugins.Persona.system_message/1`), assembles prior artifacts, constructs user messages with workspace constraints, and sends the complete messages array in the action payload. The client passes these messages directly to the LLM backend. This keeps persona content server-side and avoids duplicating persona markdown files in pyre_client.

### 5. Tools built locally from role info

Tool definitions include callback functions that can't be serialized over WebSocket. The Executor builds `ReqLLM.Tool` structs locally via `PyreClient.Tools.for_role/3` from the `role`, `working_dir`, `allowed_paths`, and `allowed_commands` in the payload.

### 6. Server owns session IDs

Session IDs are generated by the server (`Pyre.Session.generate_for_stages/1`) at flow start and included in each action payload's `opts.session_id`. The client stores the mapping (`execution_id → session_id`) for CLI session resumption during `action_continue`. The client does NOT generate session IDs for LLM sessions.

### 7. Server signals interactivity

The server includes `interactive: true|false` in each action payload. This is the authoritative signal: if `true`, the client sends `action_result` after the initial LLM call and blocks waiting for `action_continue`/`action_finish`. If `false`, the client sends `action_complete` and exits immediately. The server's flow orchestration owns the interactivity decision (based on `RunServer.interactive_stages`).

### 8. Interactive loop is shared infrastructure

The interactive loop (action_result → action_continue → action_result → action_finish) lives in the Executor, not in individual action modules. It always operates on the LLM portion. Post-LLM processing (git, GitHub, parsing) runs after the interactive loop completes. From the client's perspective, `action_continue` is always "resume the LLM session" — whether the message is a user reply or a finalize prompt.

### 9. GitHub credentials via short-lived tokens

The server sends a short-lived GitHub installation token in the `github` field of git action payloads. These are scoped to the specific repo, expire after ~1 hour, and are generated fresh per-request. The client uses `req` for 3 HTTP endpoints: create PR, create comment, mark ready for review. No credential storage on the client.

### 10. Action-specific error policies

Each action module owns its error policy:
- `Prompt`: fail on LLM error
- `GitPRSetup`, `GitShip`: fail on any git or GitHub error (with chain)
- `GitReview`: fire-and-forget for git/GitHub (action succeeds if LLM succeeds)

### 11. Streaming via output_fn

All LLM calls pass an `output_fn` callback that sends each token/line back to the server as an `action_output` event. Both `stream/3`, `chat/4`, and `AgenticLoop.run/5` support this pattern.

### 12. Capacity tracking

`max_capacity: 1` for now. Interactive executions hold the capacity slot for the full duration (potentially hours/days). The `spawn_monitor` pattern and `active_executions` tracking stay in place for future concurrency.

---

## Payload Schemas

**Note:** The payload does NOT include a `backend` field. The client determines which LLM backend to use from its own configuration. The server only sends the `model_tier`.

### `prompt` payload (covers 9 of 11 server actions)

```json
{
  "execution_id": "abc123",
  "action": "prompt",
  "payload": {
    "model_tier": "standard",
    "interactive": false,
    "messages": [
      {"role": "system", "content": "You are a software architect..."},
      {"role": "user", "content": "Design a REST API for..."}
    ],
    "role": "software_architect",
    "working_dir": "/path/to/project",
    "allowed_paths": ["/path/to/project"],
    "allowed_commands": ["mix", "elixir", "git", "ls"],
    "opts": {
      "streaming": true,
      "session_id": "uuid-for-this-stage",
      "max_turns": 50,
      "add_dirs": ["/path/to/other/app"]
    }
  }
}
```

Result: `{"text": "The architecture should..."}`

### `git_pr_setup` payload

```json
{
  "execution_id": "abc456",
  "action": "git_pr_setup",
  "payload": {
    "messages": [...],
    "model_tier": "advanced",
    "role": "shipper",
    "working_dir": "/path/to/project",
    "feature_description": "Build a products listing page",
    "run_dir": "/path/to/run/dir",
    "dry_run": false,
    "github": {
      "owner": "chrislaskey",
      "repo": "myapp",
      "token": "ghs_xxxx"
    },
    "opts": { "streaming": true, "session_id": "uuid" }
  }
}
```

Result: `{"text": "...", "branch_name": "feature/products-listing", "pr_url": "https://...", "pr_number": 42}`

### `git_ship` payload

Same shape as `git_pr_setup` but adds `allowed_paths`, `allowed_commands` (Shipper conditionally uses tools). No `dry_run` field.

```json
{
  "execution_id": "abc789",
  "action": "git_ship",
  "payload": {
    "messages": [...],
    "model_tier": "advanced",
    "role": "shipper",
    "working_dir": "/path/to/project",
    "allowed_paths": ["/path/to/project"],
    "allowed_commands": ["mix", "elixir", "git"],
    "github": {
      "owner": "chrislaskey",
      "repo": "myapp",
      "token": "ghs_xxxx"
    },
    "opts": { "streaming": true, "session_id": "uuid" }
  }
}
```

Result: `{"text": "...", "shipping_summary": "Branch: feature/x, PR: Add feature X"}`

### `git_review` payload

```json
{
  "execution_id": "abc012",
  "action": "git_review",
  "payload": {
    "messages": [...],
    "model_tier": "advanced",
    "role": "qa_reviewer",
    "working_dir": "/path/to/project",
    "run_dir": "/path/to/run/dir",
    "pr_number": 42,
    "github": {
      "owner": "chrislaskey",
      "repo": "myapp",
      "token": "ghs_xxxx"
    },
    "opts": { "streaming": true, "session_id": "uuid" }
  }
}
```

Result: `{"text": "...", "verdict": "approve"}`

### action_continue (server → client)

```json
{
  "execution_id": "def456",
  "message": "Looks good, but can you add error handling to the API endpoints?"
}
```

### action_finish (server → client)

```json
{
  "execution_id": "def456"
}
```

---

## Adding New Action Types

Adding a new action type requires:

1. **Create the action module** in `lib/pyre_client/actions/`:
   ```elixir
   defmodule PyreClient.Actions.NewType do
     @behaviour PyreClient.Actions

     @impl true
     def execute(payload, context) do
       # ...
     end
   end
   ```

2. **Register it** in `PyreClient.Actions.resolve/1`:
   ```elixir
   def resolve("new_type"), do: {:ok, PyreClient.Actions.NewType}
   ```

3. **Add the server-side dispatch** in pyre_lib (the action module that builds the payload and interprets the result).

Both libraries must be updated in lockstep. This is acceptable: there are no independent users, both are co-developed, and new action types are rare.
