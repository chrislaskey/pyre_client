# Pyre Client — Plan Overview

## What We're Building

An Elixir library (`pyre_client`) that is the **execution layer** for the Pyre platform. It owns all LLM backends, the tool system, the agentic loop, session management, and the WebSocket client that connects to a Pyre Web server.

pyre_client connects as a worker, receives dispatched actions (LLM prompts), executes them locally, and streams results back. It is a thin client with no knowledge of workflows, stages, or orchestration.

pyre_lib is the **orchestration layer** — it runs workflows, dispatches actions to workers, and serves the web UI. It does not execute actions locally or call LLM backends directly.

**CRITICAL — This is a MOVE, not a copy.** The execution modules listed below currently live in pyre_lib. They are being **relocated** to pyre_client as their permanent, sole home. After pyre_client is built, these modules will be **deleted** from pyre_lib entirely. There must be exactly ONE implementation of each module — in pyre_client. Do NOT duplicate code across both libraries. Do NOT leave stubs, re-exports, or compatibility shims in pyre_lib. The source of truth for all LLM backends, tools, the agentic loop, and session management is pyre_client. pyre_lib will be refactored later (see "Future pyre_lib Changes") to dispatch to workers instead of calling these modules directly.

## Why

pyre_lib handles orchestration: workflows, flows, actions, the run lifecycle, and the web UI. But it should not be responsible for the mechanics of executing an LLM prompt — that's the worker's job.

By making pyre_client own the entire execution layer, we get:
- **Clean separation**: orchestration (pyre_lib) vs execution (pyre_client)
- **Lightweight workers**: pyre_client depends on `req_llm` directly (zero jido/workflow dependency)
- **Flexible deployment**: same BEAM VM for local execution, or separate machines for distributed builds

## Architecture

### Orchestration vs Execution

```
pyre_lib (orchestration + UI)               pyre_client (execution)
├── Pyre.Flows.*     (workflow pipelines)   ├── PyreClient.LLM.*     (all backends)
├── Pyre.Actions.*   (action definitions)   ├── PyreClient.Tools.*   (tool sandbox + agentic loop)
├── Pyre.RunServer   (run lifecycle)        ├── PyreClient.Session.* (session management)
├── Pyre.Config      (workflow config)      ├── PyreClient.Executor  (action execution)
├── PyreWeb.*        (UI, channels)         ├── PyreClient.Connection (WebSocket)
└── depends on: jido, jido_ai              └── depends on: req_llm, websockex
         │                                           │
         └──────────────┬────────────────────────────┘
                        │
                  Host app composes both
                  (e.g., pyre_app)
```

pyre_lib and pyre_client have **no compile-time dependency** on each other. Host apps compose both.

### What Lives in pyre_client

All backend execution modules **move** from pyre_lib to pyre_client. The "Source" column shows where the existing implementation lives today — use it as the reference implementation. Adapt the code for the `PyreClient` namespace, `req_llm` direct dependency, and `:pyre_client` config namespace. Do NOT create new modules from scratch when a working implementation already exists in pyre_lib.

| Source (pyre_lib — reference impl) | Target (pyre_client — sole owner) | What it does |
|-------------------------------------|-----------------------------------|-------------|
| `Pyre.LLM` | `PyreClient.LLM` | Behaviour: `generate/3`, `stream/3`, `chat/4`, `manages_tool_loop?/0` |
| `Pyre.LLM.ReqLLM` | `PyreClient.LLM.ReqLLM` | API-based LLM calls via req_llm |
| `Pyre.LLM.ClaudeCLI` | `PyreClient.LLM.ClaudeCLI` | Claude Code CLI subprocess |
| `Pyre.LLM.CursorCLI` | `PyreClient.LLM.CursorCLI` | Cursor Agent CLI subprocess |
| `Pyre.LLM.CodexCLI` | `PyreClient.LLM.CodexCLI` | OpenAI Codex CLI subprocess |
| `Pyre.LLM.Mock` | `PyreClient.LLM.Mock` | Test mock (process dictionary) |
| `Pyre.Tools` | `PyreClient.Tools` | Tool definitions (read_file, write_file, list_directory, run_command) |
| `Pyre.Tools.AgenticLoop` | `PyreClient.Tools.AgenticLoop` | Multi-turn tool-use loop for ReqLLM backend |
| `Pyre.Session` | `PyreClient.Session` | UUID session ID generation |
| `Pyre.Session.Registry` | `PyreClient.Session.Registry` | Maps pyre session IDs to backend session IDs (CursorCLI) |
| _(new)_ | `PyreClient.LLM.Config` | Backend listing and resolution |
| _(new)_ | `PyreClient.Config` | Connection settings |
| _(new)_ | `PyreClient.Connection` | WebSockex WebSocket client |
| _(new)_ | `PyreClient.Channel` | Phoenix channel state machine |
| _(new)_ | `PyreClient.Protocol` | Phoenix V2 wire protocol |
| _(new)_ | `PyreClient.Executor` | Action dispatch and execution |

### What Stays in pyre_lib

| Module | Why |
|--------|-----|
| `Pyre.Actions.*` | Action definitions — dispatch to workers, process results |
| `Pyre.Flows.*` | Workflow orchestration — drive multi-stage pipelines |
| `Pyre.RunServer` | Run lifecycle — manage in-memory run state |
| `Pyre.Config` | Workflow config, authorization, lifecycle hooks |
| `Pyre.Plugins.*` | Persona loading, artifact management |
| `PyreWeb.*` | Web UI, LiveViews, channels, router |

After the migration is complete, pyre_lib retains **zero** LLM backends, tools, agentic loop code, or session management. All of `Pyre.LLM`, `Pyre.LLM.*`, `Pyre.Tools`, `Pyre.Tools.AgenticLoop`, `Pyre.Session`, and `Pyre.Session.Registry` will be deleted from pyre_lib. Its actions will dispatch `execute_prompt` to workers instead of calling `Helpers.call_llm/4` directly. This refactoring happens separately after pyre_client is built.

### Deployment Model

```
┌──────────────────────────────────────────────────────┐
│                 Pyre Web Server                       │
│  pyre_lib (orchestration) + PyreWeb (channels)        │
│  Host app provides: queue, worker selection, DB       │
└────────┬───────────────┬───────────────┬─────────────┘
         │ WS             │ WS             │ WS
    ┌────┴─────┐    ┌────┴─────┐    ┌────┴──────────┐
    │  Client  │    │  Client  │    │ Pyre Native   │
    │ (local)  │    │ (remote) │    │   (Swift)     │
    └──────────┘    └──────────┘    └───────────────┘
```

All worker types are identical from the server's perspective. The "local" client is just pyre_client running in the same BEAM VM, connecting via localhost WebSocket.

**Note on worker selection and queuing:** Queue management (e.g., Oban) and worker selection (e.g., picking a worker from Presence by capacity/backend) are **host-app responsibilities**, not pyre_lib concerns. pyre_lib provides the hooks (`Pyre.Config` callbacks, `PyreWeb.Presence` tracking) that host apps build on. For example, `pyre_app` implements `App.Pyre.Workers.QueueManager` (watches Presence, scales Oban queues) and `App.Workers.WorkflowJob` (selects workers, dispatches actions). pyre_client doesn't need to know about these — it just advertises its capabilities (backends, capacity, workflows) in the channel join payload.

### Execution Flow

When pyre_lib dispatches an action to a worker:

**Non-interactive** (e.g., code review, task):

```
pyre_lib (server)                    pyre_client (worker)
─────────────────                    ────────────────────
Flow.run_action()
  → dispatch execute_prompt          → Executor receives payload
    {model_tier, messages,              → resolve backend from config
     role, working_dir,                 → resolve model from tier
     interactive: false, ...}           → build tools for role
                                        → route to LLM call
  ← streams action_output             ← streams tokens/lines
  ← receives action_complete         ← sends final result text
  → processes result                    → execution done, slot freed
    (parse verdict, git ops, etc.)
```

**Interactive** (e.g., feature engineering with user feedback):

```
pyre_lib (server)                    pyre_client (worker)
─────────────────                    ────────────────────
Flow.run_action()
  → dispatch execute_prompt          → Executor receives payload
    {interactive: true, ...}            → run initial LLM call
  ← streams action_output             ← streams tokens/lines
  ← receives action_result            ← sends result (NOT complete)
                                        → blocks waiting...
  → enters interactive wait              (capacity slot stays occupied)
    (RunServer holds from ref)
                                     ...time passes...
  user replies →
  → sends action_continue             → resumes CLI session
    {message: "add tests..."}           (resume: session_id)
  ← streams action_output             ← streams tokens
  ← receives action_result            ← sends new result, blocks again

  user says continue (no replies) →
  → sends action_finish                → sends action_complete
                                        → execution exits, slot freed
  → processes final result
```

The worker handles the full LLM interaction including tool execution. The orchestration layer processes the text result (parsing, git operations, artifact writing, GitHub API calls). During interactive stages, both server and client block — the server's flow Task blocks on `await_user_action_fn`, and the client's execution process blocks in `interactive_loop`, maintaining working directory and file state consistency.

## Key Design Decisions

1. **Execution layer ownership** — pyre_client owns ALL execution: LLM backends, tools, agentic loop, session management. pyre_lib is orchestration-only.

2. **Independent peer libraries** — No compile-time dependency between pyre_lib and pyre_client. Host apps compose both.

3. **Direct `req_llm` dependency** — `req_llm` is a **standalone hex package** (confirmed — it is NOT bundled inside jido_ai). pyre_client depends on `req_llm ~> 1.9` directly, giving it access to `ReqLLM.Tool`, `ReqLLM.Response`, `ReqLLM.Context`, `ReqLLM.ToolCall`, etc. with zero jido/jido_ai dependency. pyre_lib reaches these same types through its `jido_ai` dependency, but pyre_client does not need that transitive path.

4. **Client-owned backend selection** — The server does NOT tell the client which backend to use. The server sends `model_tier` ("fast", "standard", "advanced"); the client resolves the backend from its own config (`config :pyre_client, llm_backend: :claude_cli`) and the model string from tier aliases. Each client deployment manages its own list of enabled backends. The server only sees the backends the client advertises in its join payload — it uses this for worker selection, not for directing backend choice.

5. **Tools built locally** — Tool definitions include callbacks (functions) that can't be serialized over WebSocket. The Executor builds `ReqLLM.Tool` structs locally from role/working_dir info in the payload.

6. **`manages_tool_loop?` routing** — The Executor mirrors `Helpers.call_llm/4`'s routing: CLI backends handle tools internally, ReqLLM uses AgenticLoop.

7. **Thin client** — No knowledge of workflows, stages, or orchestration. Receives individual actions, executes them, streams output back.

8. **WebSockex + Phoenix V2 protocol** — OTP-compatible WebSocket client speaking the channel wire format directly.

9. **Library, not application** — No auto-start. Host app configures and starts processes.

10. **Capacity hardcoded to 1** — `max_capacity` is 1 for now. Dynamic capacity negotiation (notifying the server when slots free up, rejecting over-capacity dispatches) is deferred. Infrastructure for future concurrency stays in place.

## Stages

| Stage | File | Description |
|-------|------|-------------|
| 1 | `PLAN_01_OVERVIEW.md` | This document |
| 2 | `PLAN_02_PROJECT_STRUCTURE.md` | Mix project, deps, config, LLM layer, tools, sessions |
| 3 | `PLAN_03_PHOENIX_PROTOCOL.md` | Phoenix Channel V2 wire protocol implementation |
| 4 | `PLAN_04_WEBSOCKET_CONNECTION.md` | WebSockex client with ping/pong keepalive |
| 5 | `PLAN_05_CHANNEL_CLIENT.md` | Channel join, presence, message handling |
| 6 | `PLAN_06_EXECUTOR.md` | Action dispatch, LLM routing, output streaming |
| 7 | `PLAN_07_TESTING.md` | Test strategy and mock patterns |

## Dependency Graph

```
Stage 2 (project structure + LLM layer + tools + sessions)
  └─→ Stage 3 (protocol layer — pure, no deps)
       └─→ Stage 4 (websocket connection)
            └─→ Stage 5 (channel client)
                 └─→ Stage 6 (executor — command + LLM execution)
                      └─→ Stage 7 (tests)
```

## Future pyre_lib Changes

When pyre_client is built, pyre_lib will need these changes (done separately):

1. **Add `pyre_client` as optional dev dependency** — only for tests that need the mock backend
2. **Remove execution modules** — `Pyre.LLM`, `Pyre.LLM.*`, `Pyre.Tools`, `Pyre.Tools.AgenticLoop`, `Pyre.Session`, `Pyre.Session.Registry`
3. **Refactor actions** — Replace `Helpers.call_llm/4` with remote dispatch to workers via WebSocket (synchronous dispatch-and-wait: PubSub subscribe → broadcast to worker → block until `action_result` or `action_complete`)
4. **Refactor interactive loops** — Server sends `action_continue` with user's reply message to the blocked worker; sends `action_finish` when the interactive loop ends. The flow Task blocks on `await_user_action_fn` as it does today — the only change is that the LLM call happens remotely instead of locally
5. **Add new channel events** — `PyreWeb.Channel` needs:
   - `handle_in("action_result", ...)` — intermediate result from interactive execution (broadcasts to PubSub like `action_output`)
   - Server-side code to `push(socket, "action_continue", ...)` and `push(socket, "action_finish", ...)` to the client
6. **Update `Pyre.Config`** — Remove `list_llm_backends/0`, `get_llm_backend/1` (backend selection is entirely owned by pyre_client — each client deployment configures its own backends)
7. **Potential orchestration-level LLM** — If pyre_lib needs lightweight LLM calls for orchestration (summarizing, parsing for tool orchestration), it would have its own simple, independent implementation — not shared with pyre_client

These changes are **not part of the pyre_client build**.
