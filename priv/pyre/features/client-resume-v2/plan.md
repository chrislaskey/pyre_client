# Client Resume V2: Graceful Fallback for Lost Session Mappings

## Problem

When pyre_client restarts, `Runner.active_executions` and `Session.Registry` are wiped. The server sends `action_continue` or `action_finish` for execution_ids the client no longer tracks:

```
[warning] [PyreClient.Runner] action_continue for unknown execution 801d5757d0b468ad
[warning] [PyreClient.Runner] action_finish for unknown execution run:b49388ad
```

Both are silently dropped. The server-side `receive_action_result` hangs until timeout.

## Changes

### Change 1: `handle_continue` — create a new session and start fresh

**File:** `runner.ex` — `handle_cast({:handle_continue, payload}, state)`

When `execution_id` is not in `active_executions`:

1. Generate a new session ID via `PyreClient.Session.generate_id()`
2. Store the mapping: `execution_id → new_session_id` (so the execution can be found on subsequent continues)
3. Spawn a new execution that mirrors the initial `execute_interactive` flow:
   - Build a context with `session_id: new_session_id` (NOT `resume:`) — so the LLM backend starts a fresh session (e.g., `--session-id <id>` for ClaudeCLI)
   - Messages: the user's message from the payload, with the resumed-conversation note prepended
   - Call `PyreClient.Actions.LLM.call(context)` — same path as the initial call
   - Send result via `action_result`
   - Enter `interactive_loop` so subsequent continues and finishes work normally
4. Register the new execution in `active_executions`

The resumed-conversation note (prepended to user's message):

```
NOTE: This is a resumed conversation, but we don't have a reference session
ID. Do your best to pick up context based on local or remote changes. Then
reply back to the user telling them you don't have access to the previous
discussion, but here is what you do know based on the prompt and existing code
(which can also be nothing — "I don't have enough to go on yet" — or if you do
have some: "here is my understanding..."), and then ask some clarifying
questions for the user so in the next response you can start doing work.
```

### Change 2: `handle_finish` — ack for unknown executions

**File:** `runner.ex` — `handle_cast({:handle_finish, payload}, state)`

When `execution_id` is not in `active_executions`:

1. Log at info level
2. Send `action_complete` with status "ok" so the server doesn't hang

```elixir
def handle_cast({:handle_finish, payload}, state) do
  execution_id = payload["execution_id"]

  case Map.get(state.active_executions, execution_id) do
    nil ->
      Logger.info(
        "[PyreClient.Runner] action_finish for unknown execution #{execution_id}, acking"
      )

      send_to_server("action_complete", %{
        "execution_id" => execution_id,
        "status" => "ok",
        "result" => %{}
      })

      {:noreply, state}

    pid ->
      send(pid, :finish)
      {:noreply, state}
  end
end
```

### DRY opportunity

The recovery path in `handle_continue` mirrors what `execute_interactive` does:
build context → LLM call → send `action_result` → enter `interactive_loop`.

We can extract a shared function (e.g., `start_interactive_session/3`) that takes
`(execution_id, context)`, does the initial LLM call, sends the result, and enters
the loop. Both the normal `execute` path (for interactive actions) and the recovery
path call this same function.

## Gap: `action_continue` doesn't carry `working_dir` or `role`

The `action_continue` payload from the server only includes:
```elixir
%{"execution_id" => "...", "message" => "..."}
```

It does NOT include `working_dir`, `role`, `model_tier`, or any original action context.

**Why this matters:** Without `working_dir`, the CLI backend doesn't know where to
run (`cd: working_dir` in run_opts). Without `role`, we can't build tools. The LLM
can respond with text but can't read files or run commands — which limits its ability
to "pick up context based on local or remote changes."

**Resolution:** Include `working_dir` in the `action_continue` payload from
`Pyre.Flows.Dispatch.send_continue/2`. The `context` already has `working_dir`
available. One-line change:

```elixir
# In Pyre.Flows.Dispatch.send_continue/2
{:action_continue, execution_id, %{
  "message" => message,
  "working_dir" => context.working_dir
}}
```

On the client side, `handle_continue` reads it and passes it through when
building the recovery context. This lets the CLI run in the right directory
and enables tools.

## Summary

| # | Where | What |
|---|-------|------|
| 1 | `runner.ex` handle_continue | Generate new session ID, start fresh interactive session with user message + resumed note |
| 2 | `runner.ex` handle_finish | Send `action_complete` ack for unknown execution_ids |
| 3 | `runner.ex` refactor | Extract shared `start_interactive_session` used by both normal and recovery paths |
| 4 | `dispatch.ex` send_continue | Include `working_dir` in `action_continue` payload |

## What this does NOT change

- No new state/persistence in Runner (no stashed payloads)
- No changes to Session.Registry
- No changes to LLM backends
