# Stage 6 — Executor

## Overview

`PyreClient.Executor` receives action dispatches from the Channel, executes LLM prompts locally via the `PyreClient.LLM` backend system, streams output back, and reports completion.

The Executor resolves the backend from the client's own config (`PyreClient.LLM.Config.default_backend/0`), resolves the model tier to a concrete model string, routes through the appropriate execution path (direct chat, AgenticLoop, stream, or generate), and streams results back to the server. The server does NOT specify which backend to use — it only sends the `model_tier`.

The Executor has **no knowledge of workflows, stages, or orchestration**. It executes individual actions the server tells it to.

**Note:** pyre_native (Swift) currently has a proof-of-concept for arbitrary shell command execution (`RemoteCommandService`). pyre_client does NOT implement that — it focuses exclusively on LLM prompt execution. Shell commands that LLM agents need are handled by the LLM backends themselves (e.g., Claude CLI's built-in Bash tool, or Pyre's `run_command` tool via the AgenticLoop).

## Action Types

| Type | Payload | What it does |
|------|---------|-------------|
| `execute_prompt` | `%{"messages" => [...], "model_tier" => "standard", ...}` | Call an LLM backend with optional tool execution. The client resolves the backend locally from its own config — the server does NOT specify which backend to use. |

## Channel Events

### Client → Server

| Event | When | Payload |
|-------|------|---------|
| `action_output` | Streaming token/line during execution | `%{"execution_id" => id, "line" => text}` |
| `action_result` | LLM call finished, interactive stage awaiting continuation | `%{"execution_id" => id, "result_text" => text}` |
| `action_complete` | Execution fully done, capacity slot freed | `%{"execution_id" => id, "status" => "ok" | "error", "result_text" => text}` |

### Server → Client

| Event | When | Payload |
|-------|------|---------|
| `action` | Dispatch new action to worker | `%{"execution_id" => id, "type" => "execute_prompt", "payload" => {...}}` |
| `action_continue` | User replied during interactive stage | `%{"execution_id" => id, "message" => text}` |
| `action_finish` | Interactive loop done, release the worker | `%{"execution_id" => id}` |

The distinction between `action_result` and `action_complete` is key:
- **`action_result`**: The LLM call is done but the execution stays alive. The capacity slot remains occupied. The spawned process blocks waiting for `action_continue` or `action_finish`.
- **`action_complete`**: The execution is fully done. The capacity slot is freed.

Non-interactive executions skip `action_result` entirely and go straight to `action_complete`.

## Execution Flow

### Non-interactive (standard)

```
Server pushes "action" event
  │
  ▼
Channel.handle_message → Executor.handle_action/1
  │
  ├─ 1. Resolve backend, model, and tools
  │    ├─ Resolve backend from client's own config (PyreClient.LLM.Config.default_backend/0)
  │    ├─ Resolve model tier → model string (PyreClient.LLM.Config.resolve_model/2)
  │    ├─ Build tools locally if role provided (PyreClient.Tools.for_role/3)
  │
  ├─ 2. Route by backend capability
  │    ├─ tools + manages_tool_loop? → backend.chat/4 (CLI handles tools)
  │    ├─ tools + !manages_tool_loop? → AgenticLoop (ReqLLM multi-turn)
  │    ├─ streaming → backend.stream/3
  │    └─ else → backend.generate/3
  │    Stream tokens → send "action_output"
  │    Collect final result
  │
  └─ 3. Send "action_complete"
       ├─ status ("ok" or "error")
       └─ result_text
```

### Interactive (blocking wait for user input)

```
Server pushes "action" event (interactive: true)
  │
  ▼
Executor.handle_action/1 → spawns execution process
  │
  ├─ 1. Run initial LLM call (same routing as non-interactive)
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
  │         ├─ Executor signals execution process to exit
  │         └─ Execution process sends "action_complete" and exits
  │
  └─ 4. Capacity slot freed on "action_complete"
```

## Module: `PyreClient.Executor`

```elixir
defmodule PyreClient.Executor do
  @moduledoc """
  Executes LLM prompt actions dispatched by the Pyre Web server.

  Routes LLM calls based on backend capability:
  - CLI backends (manages_tool_loop? = true): direct chat/4
  - ReqLLM (manages_tool_loop? = false): PyreClient.Tools.AgenticLoop

  Has no knowledge of workflows, stages, or orchestration.
  """

  use GenServer

  require Logger

  @name __MODULE__

  defstruct [
    :max_capacity,
    :active_executions  # %{execution_id => pid}  (pid of the spawned execution process)
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
    action_type = payload["type"]

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
    # Channel drops are expected — don't kill in-flight work.
    # The Connection will reconnect and rejoin automatically.
    # In-flight executions continue; output sent during disconnection
    # may be lost, but the final action_complete will be sent after
    # reconnection if the execution finishes while disconnected.
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

  # --- Action: execute_prompt ---

  defp execute(execution_id, "execute_prompt", payload) do
    inner = payload["payload"] || %{}
    model_tier = inner["model_tier"] || "standard"
    messages = inner["messages"] || []
    role = inner["role"]
    working_dir = inner["working_dir"]
    allowed_paths = inner["allowed_paths"] || []
    allowed_commands = inner["allowed_commands"]
    opts_map = inner["opts"] || %{}

    # Backend is determined entirely by the client's own config — the server
    # sends only the model_tier. The client resolves both the backend and
    # the concrete model string from its local configuration.
    backend = PyreClient.LLM.Config.default_backend()
    model = PyreClient.LLM.Config.resolve_model(model_tier, backend)

    Logger.info("[PyreClient.Executor] #{execution_id}: executing prompt via #{inspect(backend)} (tier: #{model_tier})")

    # Convert message maps to the format PyreClient.LLM expects
    messages = Enum.map(messages, fn msg ->
      %{role: String.to_existing_atom(msg["role"]), content: msg["content"]}
    end)

    # Build tools locally from role info (tool callbacks can't be serialized)
    tools = build_tools(role, working_dir, allowed_paths, allowed_commands)

    # Build opts keyword list
    opts =
      opts_map
      |> Enum.map(fn {k, v} -> {String.to_existing_atom(k), v} end)
      |> Keyword.new()

    output_fn = fn token -> send_output(execution_id, token) end

    # Route based on backend capability — mirrors Helpers.call_llm/4 logic
    result =
      cond do
        tools != [] and manages_tool_loop?(backend) ->
          # CLI backend with tools — direct chat/4 (CLI manages its own tool loop)
          backend.chat(model, messages, tools, Keyword.put(opts, :output_fn, output_fn))

        tools != [] ->
          # ReqLLM with tools — AgenticLoop (multi-turn tool-use conversation)
          log_fn = fn msg -> send_output(execution_id, msg <> "\n") end
          PyreClient.Tools.AgenticLoop.run(backend, model, messages, tools,
            streaming: Keyword.get(opts, :streaming, false),
            output_fn: output_fn,
            log_fn: log_fn,
            verbose: Keyword.get(opts, :verbose, false)
          )

        Keyword.get(opts, :streaming, true) ->
          # Streaming without tools
          backend.stream(model, messages, Keyword.put(opts, :output_fn, output_fn))

        true ->
          # Simple generation
          backend.generate(model, messages, opts)
      end

    interactive? = get_in(payload, ["payload", "interactive"]) == true

    case {result, interactive?} do
      # Interactive execution: send result, block for continuation
      {{:ok, text}, true} when is_binary(text) ->
        send_to_server("action_result", %{
          "execution_id" => execution_id,
          "result_text" => text
        })

        interactive_loop(execution_id, backend, model, tools, opts, output_fn, text)

      {{:ok, response}, true} ->
        text = extract_text(response)
        send_to_server("action_result", %{
          "execution_id" => execution_id,
          "result_text" => text
        })

        interactive_loop(execution_id, backend, model, tools, opts, output_fn, text)

      # Non-interactive execution: send complete immediately
      {{:ok, text}, false} when is_binary(text) ->
        send_to_server("action_complete", %{
          "execution_id" => execution_id,
          "status" => "ok",
          "result_text" => text
        })

      {{:ok, response}, false} ->
        text = extract_text(response)
        send_to_server("action_complete", %{
          "execution_id" => execution_id,
          "status" => "ok",
          "result_text" => text
        })

      # Error: always complete immediately
      {{:error, reason}, _} ->
        Logger.error("[PyreClient.Executor] #{execution_id}: LLM error: #{inspect(reason)}")
        send_to_server("action_complete", %{
          "execution_id" => execution_id,
          "status" => "error",
          "result_text" => "Error: #{inspect(reason)}"
        })
    end
  end

  # --- Interactive Loop ---
  # The execution process blocks here waiting for messages from the
  # Executor GenServer (which receives them from the Channel).
  # This keeps the capacity slot occupied and the working directory
  # consistent between interactive turns.

  defp interactive_loop(execution_id, backend, model, tools, opts, output_fn, _last_result) do
    receive do
      {:continue, payload} ->
        # User replied — resume the CLI session
        user_message = payload["message"] || ""
        session_id = Keyword.get(opts, :session_id)

        Logger.info("[PyreClient.Executor] #{execution_id}: interactive continue (session: #{session_id})")

        messages = [%{role: :user, content: user_message}]
        resume_opts = Keyword.put(opts, :resume, session_id)
        resume_opts = Keyword.put(resume_opts, :output_fn, output_fn)

        result =
          if manages_tool_loop?(backend) do
            backend.chat(model, messages, tools, resume_opts)
          else
            backend.generate(model, messages, resume_opts)
          end

        case result do
          {:ok, text} when is_binary(text) ->
            send_to_server("action_result", %{
              "execution_id" => execution_id,
              "result_text" => text
            })

            interactive_loop(execution_id, backend, model, tools, opts, output_fn, text)

          {:ok, response} ->
            text = extract_text(response)
            send_to_server("action_result", %{
              "execution_id" => execution_id,
              "result_text" => text
            })

            interactive_loop(execution_id, backend, model, tools, opts, output_fn, text)

          {:error, reason} ->
            Logger.error("[PyreClient.Executor] #{execution_id}: interactive LLM error: #{inspect(reason)}")
            send_to_server("action_complete", %{
              "execution_id" => execution_id,
              "status" => "error",
              "result_text" => "Error: #{inspect(reason)}"
            })
        end

      :finish ->
        # Server says interactive loop is done — release the worker
        Logger.info("[PyreClient.Executor] #{execution_id}: interactive finished")
        send_to_server("action_complete", %{
          "execution_id" => execution_id,
          "status" => "ok"
        })
    after
      @execution_timeout ->
        Logger.error("[PyreClient.Executor] #{execution_id}: interactive loop timed out")
        send_to_server("action_complete", %{
          "execution_id" => execution_id,
          "status" => "error",
          "result_text" => "Error: interactive loop timed out"
        })
    end
  end

  # --- Action: unknown ---

  defp execute(execution_id, unknown_type, _payload) do
    Logger.warning("[PyreClient.Executor] #{execution_id}: unknown action type: #{unknown_type}")

    send_to_server("action_complete", %{
      "execution_id" => execution_id,
      "status" => "error",
      "result_text" => "Unknown action type: #{unknown_type}"
    })
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

  defp manages_tool_loop?(backend) do
    function_exported?(backend, :manages_tool_loop?, 0) and backend.manages_tool_loop?()
  end

  defp extract_text(text) when is_binary(text), do: text
  defp extract_text(response) when is_map(response), do: inspect(response)
  defp extract_text(other), do: to_string(other)

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

## Key Design Decisions

### 1. `manages_tool_loop?` routing

The Executor mirrors the routing logic from pyre_lib's `Helpers.call_llm/4`:
- **CLI backends** (`manages_tool_loop? = true`): ClaudeCLI, CursorCLI, CodexCLI — these manage their own tool loop internally. The `tools` parameter in `chat/4` is ignored; the CLI uses its own built-in tools (Bash, Read, Edit, Write, Glob, Grep for Claude).
- **ReqLLM** (`manages_tool_loop? = false`): Routes through `PyreClient.Tools.AgenticLoop` for multi-turn tool-use conversations.

### 2. Tools built locally from role info

Tool definitions include callback functions (for `read_file`, `write_file`, `run_command`, etc.) that can't be serialized over WebSocket. Instead:
- The server sends **role info** in the `execute_prompt` payload: `role`, `working_dir`, `allowed_paths`, `allowed_commands`
- The Executor builds `ReqLLM.Tool` structs locally via `PyreClient.Tools.for_role/3`
- This keeps the tool sandbox (path validation, command allowlist) on the worker where the filesystem is accessible

### 3. Streaming via output_fn

For LLM calls, we pass an `output_fn` callback that sends each token/line back to the server as an `action_output` event. Both `stream/3`, `chat/4`, and `AgenticLoop.run/5` support this pattern.

### 4. Capacity tracking

The Executor hardcodes `max_capacity: 1` and processes one action at a time. Dynamic capacity negotiation (notifying the server when capacity changes, rejecting over-capacity dispatches) is deferred. The `spawn_monitor` pattern and `active_executions` tracking stay in place for when concurrency is needed later.

### 5. Interactive blocking execution

For interactive stages, the execution process stays alive after the initial LLM call, blocking in `interactive_loop/7` via a `receive` block. The Executor GenServer forwards `action_continue`/`action_finish` messages from the Channel to the blocked process via `send(pid, ...)`. This keeps the capacity slot occupied and the working directory + file state consistent between turns.

The spawned process is the natural home for this blocking — it keeps the Executor GenServer responsive (it can still handle `on_disconnected`, `handle_continue`, `handle_finish` casts) while the execution process blocks independently.

The `@execution_timeout` (24 hours) matches the workflow-level timeout. If the interactive loop times out, the execution sends `action_complete` with an error and exits.

## execute_prompt Payload Format

The server sends:

### Non-interactive prompt

**Note:** The payload does NOT include a `backend` field. The client determines which LLM backend to use from its own configuration (`config :pyre_client, llm_backend: :claude_cli`). The server only sends the `model_tier` — the client resolves both the backend and the concrete model string locally. This keeps backend management entirely within pyre_client.

```json
{
  "execution_id": "abc123",
  "type": "execute_prompt",
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

### Interactive prompt

Same as above but with `"interactive": true`. The execution process stays alive after the initial LLM call, blocking until it receives `action_continue` or `action_finish`.

```json
{
  "execution_id": "def456",
  "type": "execute_prompt",
  "payload": {
    "model_tier": "advanced",
    "interactive": true,
    "messages": [...],
    "role": "programmer",
    "working_dir": "/path/to/project",
    "allowed_paths": ["/path/to/project"],
    "opts": {
      "streaming": true,
      "session_id": "uuid-for-this-stage",
      "max_turns": 500
    }
  }
}
```

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

### Client execution steps

Non-interactive:
1. Resolves backend from client config (`config :pyre_client, llm_backend: :claude_cli` → `PyreClient.LLM.ClaudeCLI`)
2. Resolves `"standard"` tier → backend-specific model string (e.g., `"sonnet"` for ClaudeCLI, `"gpt-4o"` for CodexCLI)
3. Converts message maps to `%{role: :system, content: "..."}`
4. Builds tools from role info → `PyreClient.Tools.for_role(:software_architect, working_dir, opts)`
5. Routes: ClaudeCLI `manages_tool_loop? = true` → `backend.chat/4` directly
6. Streams tokens back as `action_output`
7. Sends `action_complete` with the final text

Interactive (same steps 1-6, then):
7. Sends `action_result` with the initial text (NOT `action_complete`)
8. Blocks waiting for `action_continue` or `action_finish`
9. On `action_continue`: resumes CLI session with `resume: session_id`, loops back to step 6
10. On `action_finish`: sends `action_complete`, execution process exits

For ReqLLM with tools, step 5 routes through `PyreClient.Tools.AgenticLoop.run/5`, which calls `backend.chat/4` in a loop, executing tool calls and feeding results back until the LLM produces a final answer.

## Adding New Action Types

Adding a new action type is a single function clause:

```elixir
defp execute(execution_id, "execute_tool", payload) do
  # New action type — handle tool execution
  # ...
end
```
