# Stage 8 — Server-Side Changes

## Overview

This document specifies the changes needed in `pyre_lib` (orchestration) and `pyre_web` (channel layer) to dispatch individual actions to pyre_client workers instead of executing them locally.

The goal: flows dispatch named action types (`prompt`, `git_pr_setup`, `git_ship`, `git_review`) over the WebSocket and block waiting for results, instead of calling `action_module.run()` directly. The existing blocking model (Task process + RunServer GenServer.call) remains — only the innermost execution call changes.

**Scope:** This document covers the server-side protocol, dispatch mechanism, and action module refactoring (how pyre_lib actions become dispatch descriptors that build payloads for pyre_client action modules).

## What Changes

### Summary

| Component | What changes | What stays the same |
|---|---|---|
| `PyreWeb.Channel` | New `handle_in` clause: `"action_result"`. New `handle_info` forwarding for `action_continue` and `action_finish`. | `"action_output"`, `"action_complete"`, `"update_metadata"`, `"ping"`, join/presence logic — all unchanged. |
| `Pyre.RunServer` | Stores `connection_id` in state. New `dispatch_fn` callback injected into flow opts. | Phase tracking, interactive blocking (`pending_from`), `send_reply/2`, `continue_stage/1`, log/output broadcasting — all unchanged. |
| Flow modules | `run_action/5` dispatches via PubSub instead of calling `action_module.run()`. `interactive_loop/8` dispatches `action_continue` instead of calling `llm.chat()`. `finalize_artifact/6` dispatches via `action_continue` with the finalize prompt. | `drive/2` recursion, phase tracking, `maybe_interactive_loop/5`, skip/dry_run checks, model resolution, artifact writing — all unchanged. |

### What does NOT change

- `Pyre.RunServer`'s core lifecycle: `start_run/2`, `handle_continue(:start_flow)`, Task spawning, `get_state/1`, `stop_run/1`
- The interactive blocking mechanism: `await_user_action_fn` → `GenServer.call` → `pending_from` → `GenServer.reply`
- `Pyre.Config` callbacks and lifecycle events
- `Pyre.Plugins.*` (Persona, Artifact, BestPractices)
- All LiveView pages
- `pyre_app`'s `WorkflowJob`, `QueueManager`, `Runs` — these continue to work as-is

---

## PubSub Topology

All communication between flows and pyre_client workers goes through PubSub → Channel → WebSocket. The existing topic patterns are reused and extended.

### Existing topics (unchanged)

| Topic | Direction | Message | Used by |
|---|---|---|---|
| `pyre:action:input:{connection_id}` | Server → Client | `{:action, execution_id, payload}` | Channel `handle_info` pushes to WebSocket |
| `pyre:action:output:{execution_id}` | Client → Server | `{:action_output, payload}` | Channel `handle_in` broadcasts from WebSocket |
| `pyre:action:output:{execution_id}` | Client → Server | `{:action_complete, payload}` | Channel `handle_in` broadcasts from WebSocket |
| `pyre:runs:{run_id}` | RunServer → WorkflowJob | `{:pyre_run_status, run_id, status}` | WorkflowJob `await_run_completion` |
| `pyre:connections` | Presence | `presence_diff` | QueueManager, LiveViews |

### New topics/messages

| Topic | Direction | Message | Used by |
|---|---|---|---|
| `pyre:action:output:{execution_id}` | Client → Server | `{:action_result, payload}` | **New.** Channel `handle_in("action_result")` broadcasts. Flow Task receives. |
| `pyre:action:input:{connection_id}` | Server → Client | `{:action_continue, execution_id, payload}` | **New.** Flow Task broadcasts. Channel `handle_info` pushes to WebSocket. |
| `pyre:action:input:{connection_id}` | Server → Client | `{:action_finish, execution_id}` | **New.** Flow Task broadcasts. Channel `handle_info` pushes to WebSocket. |

The key insight: the **same two PubSub topics** carry all traffic. `pyre:action:input:{connection_id}` is the server→client path. `pyre:action:output:{execution_id}` is the client→server path. New message types are added to these existing topics.

---

## PyreWeb.Channel Changes

### New `handle_in` clause: `"action_result"`

```elixir
def handle_in("action_result", %{"execution_id" => id} = payload, socket) do
  if pubsub = Application.get_env(:pyre, :pubsub) do
    Phoenix.PubSub.broadcast(pubsub, "pyre:action:output:#{id}", {:action_result, payload})
  end

  {:noreply, socket}
end
```

This is structurally identical to the existing `"action_output"` and `"action_complete"` handlers. The client sends it; the channel broadcasts it to the PubSub topic where the flow's Task process is listening.

### New `handle_info` clauses: forwarding `action_continue` and `action_finish`

```elixir
def handle_info({:action_continue, execution_id, payload}, socket) do
  push(socket, "action_continue", Map.put(payload, "execution_id", execution_id))
  {:noreply, socket}
end

def handle_info({:action_finish, execution_id}, socket) do
  push(socket, "action_finish", %{"execution_id" => execution_id})
  {:noreply, socket}
end
```

These follow the same pattern as the existing `{:action, execution_id, action}` handler. The flow's Task process broadcasts to `"pyre:action:input:{connection_id}"` via PubSub; the channel process receives the message and pushes it over the WebSocket.

### Full updated channel (changes only)

```elixir
defmodule PyreWeb.Channel do
  use Phoenix.Channel

  # ... existing join/3 clauses unchanged ...

  # --- handle_in ---

  # Existing (unchanged):
  def handle_in("ping", _params, socket), do: ...
  def handle_in("action_output", %{"execution_id" => id} = payload, socket), do: ...
  def handle_in("update_metadata", params, socket), do: ...
  def handle_in("action_complete", %{"execution_id" => id} = payload, socket), do: ...

  # NEW:
  def handle_in("action_result", %{"execution_id" => id} = payload, socket) do
    if pubsub = Application.get_env(:pyre, :pubsub) do
      Phoenix.PubSub.broadcast(pubsub, "pyre:action:output:#{id}", {:action_result, payload})
    end

    {:noreply, socket}
  end

  # --- handle_info ---

  # Existing (unchanged):
  def handle_info(:after_join, socket), do: ...
  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"} = msg, socket), do: ...
  def handle_info({:action, execution_id, action}, socket), do: ...

  # NEW:
  def handle_info({:action_continue, execution_id, payload}, socket) do
    push(socket, "action_continue", Map.put(payload, "execution_id", execution_id))
    {:noreply, socket}
  end

  def handle_info({:action_finish, execution_id}, socket) do
    push(socket, "action_finish", %{"execution_id" => execution_id})
    {:noreply, socket}
  end
end
```

That's it for the channel. Three new clauses total.

---

## Pyre.RunServer Changes

### New state fields

```elixir
defstruct [
  # ... existing fields ...
  :connection_id,  # NEW: assigned worker for this run
]
```

### Worker assignment at flow start

In `handle_continue(:start_flow, state)`, after generating session IDs, select a worker and store the `connection_id`:

```elixir
def handle_continue(:start_flow, state) do
  server = self()
  stages = workflow_stages(state.workflow)
  session_ids = Pyre.Session.generate_for_stages(stages)

  # NEW: select a worker for this run
  connection_id = select_worker(state.opts)

  case connection_id do
    nil ->
      # No compatible worker available
      broadcast_event(state.id, make_entry(:error, "No compatible worker available"))
      {:noreply, %{state | status: :error}}

    connection_id ->
      flow_opts =
        state.opts
        |> Keyword.put(:log_fn, fn msg -> GenServer.cast(server, {:log, msg}) end)
        |> Keyword.put(:output_fn, fn chunk -> GenServer.cast(server, {:output, chunk}) end)
        # ... existing callbacks unchanged ...
        |> Keyword.put(:session_ids, session_ids)
        # NEW: dispatch callback
        |> Keyword.put(:connection_id, connection_id)
        |> Keyword.put(:dispatch_fn, &dispatch_to_worker/3)

      flow_module = flow_module(state.workflow)

      task = Task.Supervisor.async_nolink(Jido.Action.TaskSupervisor, fn ->
        flow_module.run(state.feature_description, flow_opts)
      end)

      state = state
        |> Map.put(:session_ids, session_ids)
        |> Map.put(:connection_id, connection_id)
        |> Map.put(:task_ref, task.ref)
        |> Map.put(:task_pid, task.pid)

      {:noreply, state}
  end
end
```

### Worker selection

```elixir
defp select_worker(opts) do
  required_backend = Keyword.get(opts, :llm) |> backend_name()

  PyreWeb.Presence.list_connections()
  |> Enum.filter(fn meta ->
    status = meta["status"] || meta[:status] || "active"
    capacity = meta["available_capacity"] || meta[:available_capacity] || 0
    backends = meta["backends"] || meta[:backends] || []

    status == "active" and
      capacity > 0 and
      (required_backend == nil or required_backend in backends)
  end)
  |> Enum.max_by(fn meta ->
    meta["available_capacity"] || meta[:available_capacity] || 0
  end, fn -> nil end)
  |> case do
    nil -> nil
    meta -> meta["connection_id"] || meta[:connection_id]
  end
end

defp backend_name(nil), do: nil
defp backend_name(module) when is_atom(module) do
  # Map module to name string for Presence matching
  case module do
    Pyre.LLM.ClaudeCLI -> "claude_cli"
    Pyre.LLM.CursorCLI -> "cursor_cli"
    Pyre.LLM.CodexCLI -> "codex_cli"
    Pyre.LLM.ReqLLM -> "req_llm"
    _ -> nil
  end
end
```

This mirrors the logic in `pyre_app`'s `WorkflowJob.select_worker/1` but lives in `pyre_lib` so any host app gets it. In the future, `Pyre.Config` could expose a `select_worker/1` callback for host-app customization.

### Dispatch helper

This is a module function (not a closure) that flows call via `context.dispatch_fn`:

```elixir
@doc false
def dispatch_to_worker(connection_id, execution_id, payload) do
  pubsub = Application.get_env(:pyre, :pubsub)

  if pubsub do
    Phoenix.PubSub.broadcast(
      pubsub,
      "pyre:action:input:#{connection_id}",
      {:action, execution_id, payload}
    )
  end
end
```

---

## Flow Changes

All 6 flows share identical `run_action/5`, `interactive_loop/8`, and `finalize_artifact/6` functions. The changes below apply to all of them uniformly.

### Context additions

The flow's `run/2` function builds a `context` map from opts. Two new keys are added:

```elixir
context = %{
  # ... existing keys (llm, streaming, output_fn, log_fn, etc.) ...
  connection_id: Keyword.get(opts, :connection_id),
  dispatch_fn: Keyword.get(opts, :dispatch_fn),
}
```

### `run_action/5` — Before and After

**Before** (current code, identical in all 6 flows):

```elixir
defp run_action(action_module, stage_name, state, context, params) do
  if stage_skipped?(stage_name, context) do
    # ... fallback logic ...
  else
    if context.dry_run do
      # ... dry run logic ...
    else
      model = Helpers.resolve_model(@stage_model_tier[stage_name], context)
      # ... log stage start ...
      session_id = get_in(context, [:session_ids, @stage_to_phase[stage_name]])
      action_context = if session_id, do: Map.put(context, :session_id, session_id), else: context
      Pyre.Config.notify(:after_action_start, %{...})

      case action_module.run(params, action_context) do
        {:ok, result} ->
          Pyre.Config.notify(:after_action_complete, %{...})
          maybe_interactive_loop(stage_name, model, session_id, result, state, context)

        {:error, _} = error ->
          Pyre.Config.notify(:after_action_error, %{...})
          error
      end
    end
  end
end
```

**After:**

```elixir
defp run_action(action_module, stage_name, state, context, params) do
  if stage_skipped?(stage_name, context) do
    # ... fallback logic unchanged ...
  else
    if context.dry_run do
      # ... dry run logic unchanged ...
    else
      phase = @stage_to_phase[stage_name]
      model_tier = @stage_model_tier[stage_name]
      # Session IDs generated at flow start, included in payload for client
      session_id = get_in(context, [:session_ids, phase])
      # Server decides interactivity; included in payload as authoritative signal
      interactive? = interactive_stage?(stage_name, context)

      context.log_fn.("--- Stage: #{stage_name} [#{timestamp()}] ---")
      Pyre.Config.notify(:after_action_start, %{stage: stage_name})

      # Build the action payload from the action module's metadata.
      # Template actions (8 of 11) dispatch as "prompt".
      # QAReviewer also dispatches as "prompt" (verdict parsed server-side from result).
      # PRSetup dispatches as "git_pr_setup", Shipper as "git_ship", PRReviewer as "git_review".
      payload = build_action_payload(
        action_module, stage_name, model_tier, session_id, interactive?, state, context, params
      )

      # Dispatch to the assigned worker and wait for the result
      case dispatch_and_wait(stage_name, payload, state, context) do
        {:ok, result_text} ->
          # Post-process the result (write artifact, parse verdict, etc.)
          result = post_process_result(action_module, stage_name, result_text, state, params)
          Pyre.Config.notify(:after_action_complete, %{stage: stage_name})
          maybe_interactive_loop(stage_name, model_tier, session_id, result, state, context)

        {:error, reason} ->
          Pyre.Config.notify(:after_action_error, %{stage: stage_name, error: reason})
          {:error, reason}
      end
    end
  end
end
```

### `dispatch_and_wait/4` — New helper

This is the core of the change. It replaces the direct `action_module.run()` call with a PubSub dispatch-and-receive pattern:

```elixir
@action_timeout 660_000  # 11 minutes (covers 600s CLI timeout + overhead)

defp dispatch_and_wait(stage_name, payload, state, context) do
  execution_id = generate_execution_id()
  connection_id = context.connection_id
  pubsub = Application.get_env(:pyre, :pubsub)

  # Subscribe BEFORE dispatching (prevents race condition)
  Phoenix.PubSub.subscribe(pubsub, "pyre:action:output:#{execution_id}")

  # Dispatch to the worker
  context.dispatch_fn.(connection_id, execution_id, payload)

  # Block waiting for the result
  # The Task process blocks here — this is fine, it's a dedicated process
  receive_action_result(execution_id, context)
end

defp receive_action_result(execution_id, context) do
  receive do
    # Streaming output — forward to RunServer's output_fn, keep waiting
    {:action_output, %{"execution_id" => ^execution_id} = payload} ->
      content = payload["content"] || payload["line"] || ""
      context.output_fn.(content)
      receive_action_result(execution_id, context)

    # Interactive result — forward to RunServer's output, return result
    # (the interactive loop handles continuation separately)
    {:action_result, %{"execution_id" => ^execution_id} = payload} ->
      {:ok, payload["result_text"] || ""}

    # Final completion
    {:action_complete, %{"execution_id" => ^execution_id} = payload} ->
      case payload["status"] do
        "ok" -> {:ok, payload["result_text"] || ""}
        "error" -> {:error, payload["result_text"] || "execution failed"}
        _ -> {:ok, payload["result_text"] || ""}
      end
  after
    @action_timeout ->
      {:error, :action_timeout}
  end
end
```

Key details:
- The Task process subscribes to `"pyre:action:output:{execution_id}"` **before** dispatching. This prevents a race where the worker completes before the subscription is active.
- `action_output` messages are forwarded to `context.output_fn` (which casts to RunServer for live streaming to the UI) and then the receive loop continues.
- For **non-interactive** actions: the flow receives `action_complete` and returns.
- For **interactive** actions: the flow receives `action_result` (not `action_complete`) and returns `{:ok, result_text}`. The `interactive_loop` then takes over.

### `interactive_loop/8` — Before and After

**Before** (current code):

```elixir
defp interactive_loop(stage_name, phase, model, session_id, result, state, context, reply_count) do
  case context.await_user_action_fn.(phase) do
    :continue when reply_count == 0 ->
      {:ok, result}

    :continue ->
      finalize_artifact(stage_name, model, session_id, result, state, context)

    {:reply, user_text} ->
      messages = [%{role: :user, content: user_text}]
      opts = [resume: session_id, streaming: context.streaming, output_fn: context.output_fn, ...]

      case context.llm.chat(model, messages, [], opts) do
        {:ok, response} ->
          text = response_to_text(response)
          context.log_fn.("[Interactive] received reply (#{String.length(text)} chars)")
          interactive_loop(stage_name, phase, model, session_id,
            Map.put(result, result_field(stage_name), text), state, context, reply_count + 1)

        {:error, reason} ->
          context.log_fn.("[Interactive] LLM error: #{inspect(reason)}")
          {:ok, result}
      end
  end
end
```

**After:**

```elixir
defp interactive_loop(stage_name, phase, model_tier, session_id, result, state, context, reply_count) do
  case context.await_user_action_fn.(phase) do
    :continue when reply_count == 0 ->
      # User clicked continue without any replies — return as-is
      {:ok, result}

    :continue ->
      # User made replies then clicked continue — finalize the artifact
      finalize_artifact(stage_name, model_tier, session_id, result, state, context)

    {:reply, user_text} ->
      # User sent a reply — forward it to the blocked execution process on the worker
      execution_id = state.current_execution_id
      connection_id = context.connection_id
      pubsub = Application.get_env(:pyre, :pubsub)

      Phoenix.PubSub.broadcast(
        pubsub,
        "pyre:action:input:#{connection_id}",
        {:action_continue, execution_id, %{"message" => user_text}}
      )

      # Wait for the worker to resume the CLI session and send back the result
      case receive_action_result(execution_id, context) do
        {:ok, text} ->
          context.log_fn.("[Interactive] received reply (#{String.length(text)} chars)")
          interactive_loop(stage_name, phase, model_tier, session_id,
            Map.put(result, result_field(stage_name), text), state, context, reply_count + 1)

        {:error, reason} ->
          context.log_fn.("[Interactive] error: #{inspect(reason)}")
          {:ok, result}
      end
  end
end
```

The key change: instead of `context.llm.chat(model, messages, [], resume: session_id)`, the flow broadcasts `{:action_continue, execution_id, %{"message" => user_text}}` to the worker's PubSub topic and then calls `receive_action_result/2` to wait for the worker's response.

The worker's execution process (which is blocking in `interactive_loop` on the client side) receives the `{:continue, payload}` message, resumes the CLI session, and sends `action_result` back.

### `finalize_artifact/6` — Before and After

**Before** (current code):

```elixir
defp finalize_artifact(stage_name, model, session_id, result, state, context) do
  messages = [%{role: :user, content: @finalize_prompt}]
  opts = [resume: session_id, streaming: context.streaming, output_fn: context.output_fn, ...]

  case context.llm.chat(model, messages, [], opts) do
    {:ok, response} ->
      finalized_text = response_to_text(response)
      # ... write artifact, update result ...
    {:error, _reason} ->
      {:ok, result}
  end
end
```

**After:**

```elixir
defp finalize_artifact(stage_name, _model_tier, _session_id, result, state, context) do
  # Send the finalize prompt as an action_continue — the worker resumes
  # the same CLI session and generates the synthesized final output.
  execution_id = state.current_execution_id
  connection_id = context.connection_id
  pubsub = Application.get_env(:pyre, :pubsub)

  Phoenix.PubSub.broadcast(
    pubsub,
    "pyre:action:input:#{connection_id}",
    {:action_continue, execution_id, %{"message" => @finalize_prompt}}
  )

  case receive_action_result(execution_id, context) do
    {:ok, finalized_text} ->
      # Send action_finish to release the worker's execution process
      Phoenix.PubSub.broadcast(
        pubsub,
        "pyre:action:input:#{connection_id}",
        {:action_finish, execution_id}
      )

      # Write the finalized artifact (unchanged logic)
      case Map.get(@stage_artifact_info, stage_name) do
        nil ->
          {:ok, result}

        {field, artifact_base} ->
          {:ok, content} = Pyre.Plugins.Artifact.read_or_write(state.run_dir, artifact_base, finalized_text)
          {:ok, Map.put(result, field, content)}
      end

    {:error, _reason} ->
      # Finalize failed — use the pre-finalize result
      {:ok, result}
  end
end
```

The finalize prompt is sent as an `action_continue` message — from the worker's perspective, it's just another user reply that resumes the CLI session. After receiving the finalized result, the flow sends `action_finish` to release the worker's execution process and free the capacity slot.

### `maybe_interactive_loop/5` — Before and After

**Before:**

```elixir
defp maybe_interactive_loop(stage_name, model, session_id, result, state, context) do
  phase = @stage_to_phase[stage_name]

  if interactive_stage?(stage_name, context) do
    interactive_loop(stage_name, phase, model, session_id, result, state, context, 0)
  else
    {:ok, result}
  end
end
```

**After:**

```elixir
defp maybe_interactive_loop(stage_name, model_tier, session_id, result, state, context) do
  phase = @stage_to_phase[stage_name]

  if interactive_stage?(stage_name, context) do
    interactive_loop(stage_name, phase, model_tier, session_id, result, state, context, 0)
  else
    # Non-interactive: the worker already sent action_complete and freed capacity.
    # Nothing to do here.
    {:ok, result}
  end
end
```

For non-interactive stages, `dispatch_and_wait` already received `action_complete` — the worker has freed its capacity slot. No `action_finish` is needed.

For interactive stages, `dispatch_and_wait` received `action_result` (the worker is still holding the capacity slot). The `interactive_loop` handles continuation and finalization, and `finalize_artifact` sends `action_finish` at the end.

### Tracking `execution_id` in flow state

The flow needs to track the current `execution_id` so that `interactive_loop` and `finalize_artifact` can route continuation messages to the correct worker process. This is stored in the flow's `state` map:

```elixir
defp dispatch_and_wait(stage_name, payload, state, context) do
  execution_id = generate_execution_id()
  # Store it in state so interactive_loop can access it
  state = Map.put(state, :current_execution_id, execution_id)
  # ... dispatch and receive ...
end
```

Since `state` is passed through `drive/2` → `run_action/5` → `maybe_interactive_loop/5` → `interactive_loop/8` → `finalize_artifact/6`, this propagates naturally.

### `generate_execution_id/0`

```elixir
defp generate_execution_id do
  :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
```

---

## Execution Flow: Complete Walkthrough

### Non-interactive stage (e.g., SoftwareArchitect in Feature flow)

```
Flow Task process                    Channel/PubSub              pyre_client Worker
─────────────────                    ──────────────              ──────────────────
run_action(SoftwareArchitect, ...)
  │
  ├─ build action payload
  │   {model_tier: "advanced",
  │    interactive: false,
  │    messages: [...], role: "software_architect", ...}
  │
  ├─ subscribe("pyre:action:output:{exec_id}")
  │
  ├─ broadcast to ──────────────────► "pyre:action:input:{conn_id}"
  │   "pyre:action:input:{conn_id}"     │
  │   {:action, exec_id, payload}       ├─► Channel.handle_info
  │                                     │   push("action", payload) ──────────► Connection receives
  │                                     │                                       Channel.handle_message
  │                                     │                                       Runner.handle_action
  │                                     │                                         │
  │   [receive loop]                    │                                         ├─ resolve backend
  │     │                               │                                         ├─ build tools
  │     │                               │                                         ├─ call ClaudeCLI.chat/4
  │     │                               │                                         │
  │     ◄── {:action_output, ...} ◄─────┤◄── handle_in("action_output") ◄────────┤── stream tokens
  │     │   forward to output_fn        │                                         │
  │     │   (loop continues)            │                                         │
  │     │                               │                                         │
  │     ◄── {:action_complete, ...} ◄───┤◄── handle_in("action_complete") ◄──────┤── LLM done
  │                                     │                                         │
  ├─ {:ok, result_text}                                                           └── capacity freed
  │
  ├─ post_process_result (write artifact, parse verdict)
  │
  ├─ maybe_interactive_loop → not interactive → {:ok, result}
  │
  └─ drive/2 → next phase
```

### Interactive stage (e.g., Programmer in Feature flow with user replies)

```
Flow Task process                    Channel/PubSub              pyre_client Worker
─────────────────                    ──────────────              ──────────────────
run_action(Programmer, ...)
  │
  ├─ build payload (interactive: true)
  ├─ subscribe, dispatch
  │                                                              Runner receives
  │   [receive loop]                                               │
  │     ◄── {:action_output, ...} ◄──────────────────────────────┤── stream tokens
  │     ◄── {:action_result, ...} ◄──────────────────────────────┤── initial result
  │                                                               │
  ├─ {:ok, result_text}                                           └── blocks in interactive_loop
  │                                                                   (capacity still held)
  ├─ maybe_interactive_loop → interactive!
  │
  ├─ interactive_loop(reply_count: 0)
  │   │
  │   ├─ await_user_action_fn.(phase) → BLOCKS (GenServer.call to RunServer)
  │   │
  │   │   ... user types in LiveView ...
  │   │   ... RunServer.send_reply(id, "add error handling") ...
  │   │   ... GenServer.reply(from, {:reply, "add error handling"}) ...
  │   │
  │   ├─ returns {:reply, "add error handling"}
  │   │
  │   ├─ broadcast ──────────────────► {:action_continue, exec_id, %{"message" => "add..."}}
  │   │                                     │
  │   │                                     ├─► Channel pushes "action_continue" ──► Worker
  │   │                                     │                                        Runner forwards
  │   │                                     │                                        to blocked process
  │   │   [receive loop]                    │                                        │
  │   │     ◄── {:action_output} ◄──────────┤◄───────────────────────────────────────┤── resume session
  │   │     ◄── {:action_result} ◄──────────┤◄───────────────────────────────────────┤── new result
  │   │                                                                              └── blocks again
  │   ├─ {:ok, text} — update result
  │   │
  │   ├─ interactive_loop(reply_count: 1) → BLOCKS again
  │   │
  │   │   ... user clicks "Continue" ...
  │   │   ... RunServer.continue_stage(id) ...
  │   │   ... GenServer.reply(from, :continue) ...
  │   │
  │   ├─ returns :continue (reply_count > 0 → finalize)
  │   │
  │   └─ finalize_artifact(...)
  │       │
  │       ├─ broadcast ──────────────► {:action_continue, exec_id, %{"message" => @finalize_prompt}}
  │       │                                                          Worker resumes session
  │       │   ◄── {:action_result} ◄─────────────────────────────── finalized text
  │       │
  │       ├─ broadcast ──────────────► {:action_finish, exec_id}
  │       │                                                          Worker sends action_complete
  │       │                                                          Capacity freed
  │       │
  │       └─ write artifact, {:ok, updated_result}
  │
  └─ drive/2 → next phase
```

---

## Worker Affinity

All messages within a single execution (dispatch, streaming, interactive replies, finalize, finish) go to the **same worker** via the `connection_id` stored in RunServer state at flow start.

- **Within a stage:** The `execution_id` identifies the worker's spawned process. `action_continue` and `action_finish` messages are routed by `execution_id` within the Runner. The same worker is guaranteed because the flow always broadcasts to the same `connection_id`.

- **Across stages:** All stages in a single run use the same `connection_id`. This is required because:
  1. CLI session resumption (`--resume <session_id>`) requires the session file to exist on the worker's filesystem.
  2. CursorCLI's `Session.Registry` maps Pyre session IDs to backend IDs in an in-memory Agent on the worker.
  3. Tool state (files written during one stage) must be visible to the next stage.

- **Worker failure:** If the assigned worker disconnects mid-run, the flow's `receive_action_result` will timeout after `@action_timeout` (11 minutes), and the flow returns `{:error, :action_timeout}`. RunServer marks the run as errored. The worker selection does not failover to another worker mid-run (session state can't be transferred).

---

## Message Shape Reference

### Server → Client (via PubSub → Channel → WebSocket)

**Dispatch action:**
```elixir
# For template actions (9 of 11):
{:action, execution_id, %{
  "action" => "prompt",
  "payload" => %{
    "model_tier" => "standard",
    # Server sets interactive flag authoritatively. Client uses this to decide
    # whether to send action_result (stay alive) or action_complete (exit).
    "interactive" => false,
    # Messages are pre-built by the server, including the full persona system
    # prompt from Pyre.Plugins.Persona. Client passes them to LLM as-is.
    "messages" => [%{"role" => "system", "content" => "You are a software architect..."}, ...],
    "role" => "software_architect",
    "working_dir" => "/path/to/project",
    "allowed_paths" => ["/path/to/project"],
    "allowed_commands" => ["mix", "elixir", "git", "ls"],
    "opts" => %{
      "streaming" => true,
      # Session ID generated by server (Pyre.Session.generate_for_stages/1).
      # Client stores mapping for CLI resume during action_continue.
      "session_id" => "uuid-for-this-stage",
      "max_turns" => 50,
      "add_dirs" => ["/path/to/other/app"]
    }
  }
}}

# For git action types (PRSetup, Shipper, PRReviewer):
{:action, execution_id, %{
  "action" => "git_pr_setup",    # or "git_ship" or "git_review"
  "payload" => %{
    "model_tier" => "advanced",
    "interactive" => false,
    "messages" => [...],
    "role" => "shipper",
    "working_dir" => "/path/to/project",
    "github" => %{
      "owner" => "chrislaskey",
      "repo" => "myapp",
      "token" => "ghs_xxxx"
    },
    "opts" => %{"streaming" => true, "session_id" => "uuid"}
  }
}}
```

**Continue interactive session:**
```elixir
{:action_continue, execution_id, %{"message" => "Please add error handling"}}
```

**Finish interactive session:**
```elixir
{:action_finish, execution_id}
```

### Client → Server (via WebSocket → Channel → PubSub)

**Streaming output:**
```elixir
{:action_output, %{"execution_id" => id, "content" => "token text"}}
```

**Interactive result (execution stays alive):**
```elixir
{:action_result, %{"execution_id" => id, "result_text" => "full response text"}}
```

**Final completion (execution exits, capacity freed):**
```elixir
{:action_complete, %{"execution_id" => id, "status" => "ok" | "error", "result_text" => "..."}}
```

---

## Action Module Refactoring

Now that the `execute_action` design is finalized (see CRITICAL_ANALYSIS.md), here's how pyre_lib's action modules change:

### Two-tier taxonomy

**Template actions (9 of 11) → dispatch descriptors:**
ProductManager, Designer, SoftwareArchitect, Programmer, TestWriter, SoftwareEngineer, PrototypeEngineer, Generalist, and QAReviewer all dispatch `"prompt"`. Their `run/2` becomes `build_payload/2` which:
1. Reads persona via `Persona.system_message/1`
2. Assembles prior artifacts via `Helpers.assemble_artifacts/1`
3. Constructs the messages array
4. Returns `%{"action" => "prompt", "payload" => %{messages: [...], model_tier: tier, role: role, ...}}`

The flow's `run_action/5` calls `action_module.build_payload(params, context)`, dispatches it, receives the result text, and does any server-side post-processing:
- Most actions: write the text as an artifact
- QAReviewer: parse the verdict from the text via `QAReviewer.parse_verdict/1`

**Outlier actions (3 of 11) → full dispatch:**
PRSetup, Shipper, PRReviewer dispatch their named types (`"git_pr_setup"`, `"git_ship"`, `"git_review"`). Their payloads include `github` credentials (short-lived installation tokens) and action-specific fields. The **client** owns the full lifecycle: LLM call, response parsing, git ops, GitHub API calls.

The flow's `run_action/5` calls `action_module.build_payload(params, context)`, dispatches it, and interprets the structured result:
- `git_pr_setup` returns `%{"branch_name" => ..., "pr_url" => ..., "pr_number" => ...}`
- `git_ship` returns `%{"shipping_summary" => ...}`
- `git_review` returns `%{"verdict" => "approve" | "reject"}`

### `build_action_payload/8` — Sketch

```elixir
defp build_action_payload(action_module, stage_name, model_tier, session_id, interactive?, state, context, params) do
  # Each action module exposes metadata for payload construction
  action_type = action_module.action_type()  # "prompt", "git_pr_setup", etc.
  role = action_module.role()

  # SERVER loads persona and builds full messages array. The client receives
  # pre-built messages and passes them directly to the LLM — no persona
  # files needed on the client side.
  {:ok, system_msg} = Pyre.Plugins.Persona.system_message(action_module.persona())
  user_msg = action_module.build_user_message(params, state, context)

  messages = [
    %{"role" => "system", "content" => system_msg.content},
    %{"role" => "user", "content" => user_msg}
  ]

  payload = %{
    "action" => action_type,
    "payload" => %{
      "model_tier" => to_string(model_tier),
      # interactive flag is the authoritative signal to the client:
      # true → send action_result and block for continuation
      # false → send action_complete and free capacity immediately
      "interactive" => interactive?,
      "messages" => messages,
      "role" => to_string(role),
      "working_dir" => context.working_dir,
      "allowed_paths" => context.allowed_paths,
      "opts" => %{
        "streaming" => context.streaming,
        # Session ID generated by server (Pyre.Session.generate_for_stages/1).
        # Client stores the mapping for CLI session resumption during
        # action_continue. Client does NOT generate session IDs.
        "session_id" => session_id,
        "max_turns" => context.max_turns || 50
      }
    }
  }

  # Git actions add GitHub credentials and action-specific fields
  if action_type in ["git_pr_setup", "git_ship", "git_review"] do
    put_in(payload, ["payload", "github"], build_github_config(context))
  else
    payload
  end
end
```

### `interpret_result/3` — Sketch

```elixir
defp interpret_result(action_module, stage_name, result) do
  action_type = action_module.action_type()

  case action_type do
    "prompt" ->
      text = result["text"]
      # QAReviewer parses verdict server-side
      if function_exported?(action_module, :parse_result, 1) do
        action_module.parse_result(text)
      else
        %{result_field(stage_name) => text}
      end

    "git_pr_setup" ->
      %{
        pr_setup: result["text"],
        branch_name: result["branch_name"],
        pr_url: result["pr_url"],
        pr_number: result["pr_number"]
      }

    "git_ship" ->
      %{shipping: result["text"], shipping_summary: result["shipping_summary"]}

    "git_review" ->
      %{review: result["text"], verdict: String.to_existing_atom(result["verdict"])}
  end
end
```

---

## Open Items (remaining)

1. **Payload key standardization** — The existing `connected_apps_list_live.ex` and `home_live.ex` read `payload["line"]` for `action_output`. The pyre_client plan uses `"content"`. Both should be supported during transition, or the LiveViews updated to read `"content"`.

2. **Worker selection callback** — `select_worker/1` is currently a private function in RunServer. Host apps may want to customize this (e.g., prefer specific workers, implement round-robin). Consider exposing it as a `Pyre.Config` callback.

3. **Timeout tuning** — The `@action_timeout` of 11 minutes covers the CLI's 600s internal timeout. Interactive stages don't use this timeout (they use the 7-day `@interactive_wait_timeout` from RunServer). But a misconfigured CLI timeout or a hung process could exceed 11 minutes. Consider making this configurable.

4. **`run_action/5` deduplication** — All 6 flows copy-paste the same `run_action/5`, `interactive_loop/8`, `finalize_artifact/6`, `maybe_interactive_loop/5`. This refactoring is a good opportunity to extract these into a shared module (e.g., `Pyre.Flows.Dispatch`).
