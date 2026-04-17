# Stage 6 — Executor

## Overview

`PyreClient.Executor` is the Elixir equivalent of pyre_native's `RemoteCommandService`, extended with full LLM backend support including tool execution. It receives action dispatches from the Channel, routes by action type, executes locally, streams output back, and reports completion.

The Executor handles two categories of work:
1. **Shell commands** — same as pyre_native: run commands via `Port`, stream output
2. **LLM prompts** — resolve a backend via `PyreClient.LLM.Config`, route through the appropriate execution path (direct chat, AgenticLoop, stream, or generate), stream results back

The Executor has **no knowledge of workflows, stages, or orchestration**. It executes individual actions the server tells it to.

## pyre_native Reference

For context, here's what the Swift `RemoteCommandService` does:

```swift
// 1. Receives commands array
// 2. Executes each sequentially via ShellExecutor.stream()
// 3. Streams output line-by-line: channel.pushAsync("action_output", ...)
// 4. Tracks exit codes per command
// 5. Stops on first failure
// 6. Sends completion: channel.pushAsync("action_complete", ...)
```

Our Executor mirrors this for shell commands, and adds LLM prompt execution using the full `PyreClient.LLM` backend system with tool support.

## Action Types

| Type | Payload | What it does |
|------|---------|-------------|
| `execute_commands` | `%{"commands" => ["cmd1", ...]}` | Run shell commands sequentially via Port |
| `execute_prompt` | `%{"messages" => [...], "model" => "...", ...}` | Call an LLM backend with optional tool execution |

## Execution Flow

```
Server pushes "action" event
  │
  ▼
Channel.handle_message → Executor.handle_action/1
  │
  ├─ 1. Route by action type
  │    ├─ "execute_commands" → run shell commands
  │    ├─ "execute_prompt"   → call LLM backend
  │    └─ unknown → log warning, send failure
  │
  ├─ 2a. Shell commands: execute sequentially via Port
  │    ├─ Stream stdout/stderr line-by-line → send "action_output"
  │    ├─ Collect exit code per command
  │    └─ Stop on first non-zero exit code
  │
  ├─ 2b. LLM prompt: resolve backend, route by capability
  │    ├─ Resolve backend module via PyreClient.LLM.Config.get_backend/1
  │    ├─ Build tools locally if role provided (PyreClient.Tools.for_role/3)
  │    ├─ Route:
  │    │    ├─ tools + manages_tool_loop? → backend.chat/4 (CLI handles tools)
  │    │    ├─ tools + !manages_tool_loop? → AgenticLoop (ReqLLM multi-turn)
  │    │    ├─ streaming → backend.stream/3
  │    │    └─ else → backend.generate/3
  │    ├─ Stream tokens/lines → send "action_output"
  │    └─ Collect final result
  │
  └─ 3. Send "action_complete"
       ├─ exit_codes (commands) or status (prompt)
       └─ result_text (prompt output)
```

## Module: `PyreClient.Executor`

```elixir
defmodule PyreClient.Executor do
  @moduledoc """
  Executes actions dispatched by the Pyre Web server.

  Handles two action types:
  - `execute_commands`: Shell commands via Port (mirrors pyre_native)
  - `execute_prompt`: LLM calls via PyreClient.LLM backends with tool support

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
    :active_executions  # %{execution_id => pid}
  ]

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
    for {_id, pid} <- state.active_executions, Process.alive?(pid) do
      Process.exit(pid, :shutdown)
    end

    Logger.warning("[PyreClient.Executor] Disconnected, killed #{map_size(state.active_executions)} active executions")
    {:noreply, %{state | active_executions: %{}}}
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

  # --- Action: execute_commands ---

  defp execute(execution_id, "execute_commands", payload) do
    commands = get_in(payload, ["payload", "commands"]) || []
    Logger.info("[PyreClient.Executor] #{execution_id}: executing #{length(commands)} commands")

    exit_codes = run_commands_sequentially(execution_id, commands)

    send_to_server("action_complete", %{
      "execution_id" => execution_id,
      "exit_codes" => exit_codes
    })
  end

  # --- Action: execute_prompt ---

  defp execute(execution_id, "execute_prompt", payload) do
    inner = payload["payload"] || %{}
    backend_name = inner["backend"]
    model = inner["model"] || "standard"
    messages = inner["messages"] || []
    role = inner["role"]
    working_dir = inner["working_dir"]
    allowed_paths = inner["allowed_paths"] || []
    allowed_commands = inner["allowed_commands"]
    opts_map = inner["opts"] || %{}

    Logger.info("[PyreClient.Executor] #{execution_id}: executing prompt via #{backend_name || "default"}")

    # Resolve the backend module
    backend = PyreClient.LLM.Config.get_backend(backend_name)

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

    case result do
      {:ok, text} when is_binary(text) ->
        send_to_server("action_complete", %{
          "execution_id" => execution_id,
          "exit_codes" => [0],
          "result_text" => text
        })

      {:ok, response} ->
        # ReqLLM.Response struct or similar
        text = if is_map(response), do: inspect(response), else: to_string(response)
        send_to_server("action_complete", %{
          "execution_id" => execution_id,
          "exit_codes" => [0],
          "result_text" => text
        })

      {:error, reason} ->
        Logger.error("[PyreClient.Executor] #{execution_id}: LLM error: #{inspect(reason)}")
        send_to_server("action_complete", %{
          "execution_id" => execution_id,
          "exit_codes" => [1],
          "result_text" => "Error: #{inspect(reason)}"
        })
    end
  end

  # --- Action: unknown ---

  defp execute(execution_id, unknown_type, _payload) do
    Logger.warning("[PyreClient.Executor] #{execution_id}: unknown action type: #{unknown_type}")

    send_to_server("action_complete", %{
      "execution_id" => execution_id,
      "exit_codes" => [1]
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

  # --- Shell Command Execution ---

  defp run_commands_sequentially(execution_id, commands) do
    run_commands_sequentially(execution_id, commands, 0, [])
  end

  defp run_commands_sequentially(_execution_id, [], _index, exit_codes) do
    Enum.reverse(exit_codes)
  end

  defp run_commands_sequentially(execution_id, [cmd | rest], index, exit_codes) do
    send_output(execution_id, "[cmd #{index}] #{cmd}")

    exit_code = stream_command(execution_id, cmd, index)
    new_exit_codes = [exit_code | exit_codes]

    if exit_code == 0 do
      run_commands_sequentially(execution_id, rest, index + 1, new_exit_codes)
    else
      remaining = List.duplicate(-1, length(rest))
      Enum.reverse(new_exit_codes) ++ remaining
    end
  end

  @doc false
  def stream_command(execution_id, command, command_index) do
    port =
      Port.open({:spawn, command}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:line, 4096}
      ])

    collect_port_output(port, execution_id, command_index)
  end

  defp collect_port_output(port, execution_id, command_index) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        send_output(execution_id, line, command_index)
        collect_port_output(port, execution_id, command_index)

      {^port, {:data, {:noeol, line}}} ->
        send_output(execution_id, line, command_index)
        collect_port_output(port, execution_id, command_index)

      {^port, {:exit_status, status}} ->
        status
    after
      3_600_000 ->
        Port.close(port)
        send_output(execution_id, "[timeout] Command timed out after 1 hour")
        1
    end
  end

  # --- Output Streaming ---

  defp send_output(execution_id, line, command_index \\ nil) do
    payload = %{
      "execution_id" => execution_id,
      "line" => line
    }

    payload =
      if command_index, do: Map.put(payload, "command_index", command_index), else: payload

    send_to_server("action_output", payload)
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

## Comparison with pyre_native

| Aspect | pyre_native (Swift) | pyre_client (Elixir) |
|--------|---------------------|----------------------|
| Process model | `RemoteCommandService.shared` singleton | `GenServer` with name registration |
| Shell execution | `Subprocess` API with `AsyncBytes` | `Port.open/2` with `:line` mode |
| LLM execution | Not supported | Full backend system with tool support |
| Tool execution | Not supported | CLI backends: internal tools; ReqLLM: AgenticLoop |
| Output streaming | `channel.pushAsync("action_output", ...)` | `WebSockex.cast(Connection, {:send_event, ...})` |
| Sequential execution | For loop, break on failure | Recursive function, stop on non-zero |
| Exit code tracking | Array of exit codes per command | Same — array of exit codes |
| Completion | `channel.pushAsync("action_complete", ...)` | Same via `send_to_server` |
| Unknown types | `DebugLogger.warning(...)` | `Logger.warning(...)`, send failure completion |
| Backend selection | N/A | `PyreClient.LLM.Config.get_backend/1` |

## Key Design Decisions

### 1. Port-based command execution

Using `Port.open/2` with `{:spawn, command}` gives us:
- Line-by-line streaming via `{:line, 4096}` option
- Exit code via `:exit_status`
- Combined stdout+stderr via `:stderr_to_stdout`
- Non-blocking — runs in a separate OS process

### 2. Sequential execution, stop on failure

Matches pyre_native behavior exactly. Commands run one at a time; first failure stops the sequence. Remaining commands get exit code `-1` (not executed).

### 3. `manages_tool_loop?` routing

The Executor mirrors the routing logic from pyre_lib's `Helpers.call_llm/4`:
- **CLI backends** (`manages_tool_loop? = true`): ClaudeCLI, CursorCLI, CodexCLI — these manage their own tool loop internally. The `tools` parameter in `chat/4` is ignored; the CLI uses its own built-in tools (Bash, Read, Edit, Write, Glob, Grep for Claude).
- **ReqLLM** (`manages_tool_loop? = false`): Routes through `PyreClient.Tools.AgenticLoop` for multi-turn tool-use conversations.

### 4. Tools built locally from role info

Tool definitions include callback functions (for `read_file`, `write_file`, `run_command`, etc.) that can't be serialized over WebSocket. Instead:
- The server sends **role info** in the `execute_prompt` payload: `role`, `working_dir`, `allowed_paths`, `allowed_commands`
- The Executor builds `ReqLLM.Tool` structs locally via `PyreClient.Tools.for_role/3`
- This keeps the tool sandbox (path validation, command allowlist) on the worker where the filesystem is accessible

### 5. Streaming via output_fn

For LLM calls, we pass an `output_fn` callback that sends each token/line back to the server as an `action_output` event. Both `stream/3`, `chat/4`, and `AgenticLoop.run/5` support this pattern.

### 6. Capacity tracking

The Executor tracks concurrent executions and updates server Presence metadata in real-time.

## execute_prompt Payload Format

The server sends:

```json
{
  "execution_id": "abc123",
  "type": "execute_prompt",
  "payload": {
    "backend": "claude_cli",
    "model": "sonnet",
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

The client:
1. Resolves `"claude_cli"` → `PyreClient.LLM.ClaudeCLI`
2. Converts message maps to `%{role: :system, content: "..."}`
3. Builds tools from role info → `PyreClient.Tools.for_role(:software_architect, working_dir, opts)`
4. Routes: ClaudeCLI `manages_tool_loop? = true` → `backend.chat/4` directly (tools ignored by CLI)
5. Streams tokens back as `action_output`
6. Sends `action_complete` with the final text

For ReqLLM with tools, step 4 would instead route through `PyreClient.Tools.AgenticLoop.run/5`, which calls `backend.chat/4` in a loop, executing tool calls and feeding results back until the LLM produces a final answer.

## Adding New Action Types

Adding a new action type is a single function clause:

```elixir
defp execute(execution_id, "execute_tool", payload) do
  # New action type — handle tool execution
  # ...
end
```
