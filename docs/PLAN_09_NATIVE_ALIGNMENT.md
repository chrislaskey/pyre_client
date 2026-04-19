# Stage 9 — pyre_native Alignment

## Overview

This document specifies the changes needed in `pyre_native` (Swift iOS/macOS client) to align with the channel protocol established by `pyre_client`.

pyre_native is a **peer worker** to pyre_client — it receives the same action types (`prompt`, `git_pr_setup`, `git_ship`, `git_review`), speaks the same wire protocol, and executes actions locally using its own Swift implementations. The server treats both worker types identically. The difference is implementation language and runtime: pyre_client uses Elixir LLM backends and system commands; pyre_native uses Swift subprocess management (e.g., Claude CLI via `ShellExecutor`).

The current `execute_commands` action type — where the server sends arbitrary shell commands — was a temporary proof-of-concept for streaming over WebSocket. It is removed entirely. pyre_native will never execute arbitrary commands sent by the server. Instead, it receives named action types with data payloads (messages, model tier, role, etc.) and decides internally what to execute.

**Scope:** This document covers protocol alignment (must-have) and the architectural pattern for native action handlers. Individual action handler implementations (e.g., `PromptActionHandler` using Claude CLI) are documented at a design level but implementation details are deferred.

## Current State

### What pyre_native does today

| Area | Current Implementation |
|------|----------------------|
| Channel | Joins `pyre:connections` with system info (name, cpu, memory, os) |
| Join payload | `{name, cpu_cores, cpu_brand, memory_gb, os_version, connection_id}` |
| Inbound events | `"action"` — dispatches by `type` field |
| Action types | `"execute_commands"` only (arbitrary shell commands, macOS only) |
| Outbound events | `"action_output"` (per-line, fire-and-forget), `"action_complete"` (with exit_codes) |
| Missing events | `"action_result"`, `"action_continue"`, `"action_finish"` — not implemented |
| Capacity | No concept — accepts any action regardless of current state |
| Interactive | Not supported |

### What it becomes

| Area | Target State |
|------|-------------|
| Channel | Joins `pyre:connections` with system info + worker capabilities |
| Join payload | Adds `status`, `available_capacity`, `backends`, `enabled_workflows` |
| Inbound events | `"action"`, `"action_continue"`, `"action_finish"` |
| Action types | `"prompt"`, `"git_pr_setup"`, `"git_ship"`, `"git_review"` — same as pyre_client |
| Outbound events | `"action_output"`, `"action_result"`, `"action_complete"` — aligned payloads |
| Capacity | Tracked by NativeExecutor, advertised via presence metadata |
| Interactive | Full support via `action_result` → `action_continue` → `action_finish` loop |

### What gets removed

| Item | Reason |
|------|--------|
| `"execute_commands"` action type | Security: server must never send arbitrary shell commands |
| `RemoteCommandService` | Replaced by `NativeExecutor` + action handler modules |
| `payload["type"]` dispatch key | Replaced by `payload["action"]` (aligned with pyre_client) |
| `"line"` key in action_output | Replaced by `"content"` (aligned with pyre_client) |
| `"exit_codes"` in action_complete | Replaced by `"status"` + `"result"` map (aligned with pyre_client) |

---

## Change 1: Join Payload Alignment

### Before

```swift
// ConnectionPresenceService.swift
let info = ConnectionInfo.current()
var params = info.toDictionary()
params["connection_id"] = info.connectionId

// Produces:
// {
//   "name": "Chris's MacBook Pro",
//   "cpu_cores": 10,
//   "cpu_brand": "Apple M3 Max",
//   "memory_gb": 36,
//   "os_version": "macOS 14.6",
//   "connection_id": "550e8400-..."
// }
```

### After

```swift
let info = ConnectionInfo.current()
var params = info.toDictionary()
params["connection_id"] = info.connectionId

// New fields — align with pyre_client's PyreClient.Config
params["status"] = "active"
params["available_capacity"] = NativeExecutor.shared.availableCapacity
params["backends"] = NativeExecutor.shared.supportedBackends
params["enabled_workflows"] = []  // empty = all

// Produces:
// {
//   "name": "Chris's MacBook Pro",
//   ...system info...
//   "connection_id": "550e8400-...",
//   "status": "active",
//   "available_capacity": 1,
//   "backends": ["claude_cli"],
//   "enabled_workflows": []
// }
```

The `backends` field advertises the same backend names as pyre_client (e.g., `"claude_cli"`). The server's `select_worker/1` uses this to route actions to compatible workers — it doesn't distinguish between a pyre_client worker advertising `"claude_cli"` (Elixir subprocess) and a pyre_native worker advertising `"claude_cli"` (Swift subprocess). Both can execute `prompt` actions using Claude CLI.

---

## Change 2: Action Dispatch Protocol

### Before

```swift
newChannel.on("action") { payload in
    guard let executionId = payload["execution_id"] as? String,
          let type = payload["type"] as? String,
          let innerPayload = payload["payload"] as? [String: Any]
    else { return }

    switch type {
    case "execute_commands":
        RemoteCommandService.shared.execute(commands: commands, ...)
    default:
        DebugLogger.warning("Unknown action type: \(type)")
    }
}
```

### After

```swift
// ConnectionPresenceService.swift
newChannel.on("action") { [weak newChannel] payload in
    guard let channel = newChannel,
          let executionId = payload["execution_id"] as? String,
          let actionType = payload["action"] as? String,
          let innerPayload = payload["payload"] as? [String: Any]
    else { return }

    NativeExecutor.shared.dispatch(
        executionId: executionId,
        actionType: actionType,
        payload: innerPayload,
        channel: channel
    )
}

newChannel.on("action_continue") { payload in
    guard let executionId = payload["execution_id"] as? String else { return }
    NativeExecutor.shared.handleContinue(executionId: executionId, payload: payload)
}

newChannel.on("action_finish") { payload in
    guard let executionId = payload["execution_id"] as? String else { return }
    NativeExecutor.shared.handleFinish(executionId: executionId)
}
```

**Key changes:**
- Top-level dispatch key: `"action"` (not `"type"`)
- Routes to `NativeExecutor` (not `RemoteCommandService`)
- Registers handlers for `action_continue` and `action_finish` (interactive loop)

---

## Change 3: Payload Alignment

All payloads match pyre_client's wire format exactly. The server builds identical payloads regardless of which worker type receives them.

### action (server → client)

**Before:**
```json
{
  "execution_id": "abc123",
  "type": "execute_commands",
  "payload": { "commands": ["ls -la", "pwd"] }
}
```

**After (identical to pyre_client):**
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
      "max_turns": 50
    }
  }
}
```

The server builds messages with full persona system prompts, includes session IDs, and sets the `interactive` flag — exactly as specified in PLAN_06 and PLAN_08. pyre_native receives the same payload a pyre_client worker would receive.

### action_output (client → server)

**Before:** `{"execution_id": "...", "line": "...", "command_index": 0}`
**After:** `{"execution_id": "...", "content": "..."}`

### action_result (client → server) — NEW

```json
{"execution_id": "...", "result_text": "Full LLM response text..."}
```

Sent when `interactive: true` — execution stays alive for continuation.

### action_complete (client → server)

**Before:** `{"execution_id": "...", "exit_codes": [0, 0]}`
**After:** `{"execution_id": "...", "status": "ok", "result": {"text": "..."}}`

For `prompt` actions: `result` contains `{"text": "..."}`.
For `git_*` actions: `result` contains structured data (branch_name, pr_url, verdict, etc.) matching pyre_client's result shapes.

### action_continue / action_finish (server → client) — NEW

```json
{"execution_id": "...", "message": "Please add error handling to the API endpoints"}
{"execution_id": "..."}
```

Same wire format as pyre_client receives. On `action_continue`, the native client resumes the LLM session with the message. On `action_finish`, it runs post-processing and sends `action_complete`.

---

## Change 4: NativeExecutor Service

Replaces `RemoteCommandService`. Mirrors pyre_client's `PyreClient.Executor` pattern: action routing, capacity tracking, interactive loop infrastructure.

```swift
/// Routes dispatched actions to handler modules, tracks capacity, and
/// manages the interactive loop. Mirrors PyreClient.Executor's role.
@MainActor
final class NativeExecutor: ObservableObject {
    static let shared = NativeExecutor()

    @Published private(set) var activeExecution: ActiveExecution?
    @Published private(set) var isRunning = false

    private let maxCapacity = 1

    var availableCapacity: Int {
        isRunning ? 0 : maxCapacity
    }

    var supportedBackends: [String] {
        #if os(macOS)
        // Advertises same backend names as pyre_client.
        // The server routes actions to workers with matching backends.
        return ["claude_cli"]
        #else
        return []  // iOS: no LLM execution yet
        #endif
    }

    // MARK: - Action Dispatch

    func dispatch(
        executionId: String,
        actionType: String,
        payload: [String: Any],
        channel: PhoenixChannelLiveView
    ) {
        guard !isRunning else {
            DebugLogger.warning("NativeExecutor at capacity, rejecting \(executionId)")
            channel.pushAsync("action_complete", [
                "execution_id": executionId,
                "status": "error",
                "result": ["error": "Worker at capacity"]
            ])
            return
        }

        guard let handler = resolveHandler(actionType) else {
            DebugLogger.warning("Unsupported action type: \(actionType)")
            channel.pushAsync("action_complete", [
                "execution_id": executionId,
                "status": "error",
                "result": ["error": "Unsupported action type: \(actionType)"]
            ])
            return
        }

        isRunning = true
        let interactive = (payload["interactive"] as? Bool) ?? false
        activeExecution = ActiveExecution(
            id: executionId,
            actionType: actionType,
            interactive: interactive,
            channel: channel
        )

        updateCapacity(channel: channel)

        Task {
            await handler.execute(
                executionId: executionId,
                payload: payload,
                channel: channel,
                executor: self
            )
        }
    }

    // MARK: - Interactive Loop

    func handleContinue(executionId: String, payload: [String: Any]) {
        guard let execution = activeExecution, execution.id == executionId else {
            DebugLogger.warning("action_continue for unknown execution: \(executionId)")
            return
        }
        execution.continuationHandler?(payload)
    }

    func handleFinish(executionId: String) {
        guard let execution = activeExecution, execution.id == executionId else {
            DebugLogger.warning("action_finish for unknown execution: \(executionId)")
            return
        }
        execution.finishHandler?()
    }

    // MARK: - Completion

    func executionComplete(executionId: String, channel: PhoenixChannelLiveView) {
        guard activeExecution?.id == executionId else { return }
        activeExecution = nil
        isRunning = false
        updateCapacity(channel: channel)
    }

    // MARK: - Routing

    /// Routes action types to handler modules.
    /// Same action types as pyre_client — both workers are peers.
    private func resolveHandler(_ actionType: String) -> NativeActionHandler? {
        #if os(macOS)
        switch actionType {
        case "prompt":       return PromptActionHandler()
        case "git_pr_setup": return GitPRSetupActionHandler()
        case "git_ship":     return GitShipActionHandler()
        case "git_review":   return GitReviewActionHandler()
        default:             return nil
        }
        #else
        return nil  // iOS: no action execution yet
        #endif
    }

    private func updateCapacity(channel: PhoenixChannelLiveView) {
        channel.pushAsync("update_metadata", [
            "available_capacity": availableCapacity
        ])
    }
}
```

### Supporting Types

```swift
struct ActiveExecution {
    let id: String
    let actionType: String
    let interactive: Bool
    let channel: PhoenixChannelLiveView
    var continuationHandler: (([String: Any]) -> Void)?
    var finishHandler: (() -> Void)?
}

protocol NativeActionHandler {
    func execute(
        executionId: String,
        payload: [String: Any],
        channel: PhoenixChannelLiveView,
        executor: NativeExecutor
    ) async
}
```

---

## Change 5: Action Handler Architecture

Each action type gets a dedicated handler module, mirroring pyre_client's `PyreClient.Actions.*` modules. The handlers use `ShellExecutor` to run CLI subprocesses (e.g., `claude` for LLM calls, `git` for git operations) and stream output back to the server.

### PromptActionHandler (design)

Handles the `prompt` action type — the same action that covers 9 of 11 server-side actions in pyre_client. Receives pre-built messages (including persona system prompt) from the server and calls Claude CLI as a subprocess.

```swift
#if os(macOS)
/// Handles "prompt" actions by calling Claude CLI as a subprocess.
///
/// The server sends pre-built messages (system prompt with persona,
/// user message with artifacts/context). This handler translates them
/// into a Claude CLI invocation, streams output back, and returns the
/// result text.
///
/// Mirrors PyreClient.Actions.Prompt — same payload, same result shape.
struct PromptActionHandler: NativeActionHandler {

    func execute(
        executionId: String,
        payload: [String: Any],
        channel: PhoenixChannelLiveView,
        executor: NativeExecutor
    ) async {
        let messages = payload["messages"] as? [[String: Any]] ?? []
        let opts = payload["opts"] as? [String: Any] ?? [:]
        let interactive = (payload["interactive"] as? Bool) ?? false
        let sessionId = opts["session_id"] as? String
        let workingDir = payload["working_dir"] as? String

        // Build Claude CLI arguments from payload
        let cliArgs = buildCLIArgs(
            messages: messages,
            sessionId: sessionId,
            workingDir: workingDir,
            opts: opts
        )

        // Run Claude CLI, streaming output
        var resultText = ""
        do {
            let status = try await ShellExecutor.stream(
                cliArgs.joined(separator: " "),
                onStart: { _ in },
                onLine: { line in
                    await MainActor.run {
                        resultText += line + "\n"
                        channel.pushAsync("action_output", [
                            "execution_id": executionId,
                            "content": line
                        ])
                    }
                }
            )

            guard status.isSuccess else {
                await sendError(executionId: executionId, reason: "CLI exited with error", channel: channel, executor: executor)
                return
            }
        } catch {
            await sendError(executionId: executionId, reason: error.localizedDescription, channel: channel, executor: executor)
            return
        }

        if interactive {
            // Send action_result, block for continuation
            channel.pushAsync("action_result", [
                "execution_id": executionId,
                "result_text": resultText
            ])

            await interactiveLoop(
                executionId: executionId,
                sessionId: sessionId,
                workingDir: workingDir,
                channel: channel,
                executor: executor,
                lastText: resultText
            )
        } else {
            // Non-interactive: send action_complete
            channel.pushAsync("action_complete", [
                "execution_id": executionId,
                "status": "ok",
                "result": ["text": resultText]
            ])
            await MainActor.run {
                executor.executionComplete(executionId: executionId, channel: channel)
            }
        }
    }

    // MARK: - Interactive Loop

    /// Mirrors pyre_client's Executor interactive_loop.
    /// Blocks until action_finish, resuming CLI sessions on action_continue.
    private func interactiveLoop(
        executionId: String,
        sessionId: String?,
        workingDir: String?,
        channel: PhoenixChannelLiveView,
        executor: NativeExecutor,
        lastText: String
    ) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task { @MainActor in
                executor.activeExecution?.continuationHandler = { payload in
                    let userMessage = payload["message"] as? String ?? ""

                    Task {
                        // Resume CLI session with user's message
                        let resumeArgs = self.buildResumeArgs(
                            message: userMessage,
                            sessionId: sessionId,
                            workingDir: workingDir
                        )

                        var newText = ""
                        do {
                            let _ = try await ShellExecutor.stream(
                                resumeArgs.joined(separator: " "),
                                onStart: { _ in },
                                onLine: { line in
                                    await MainActor.run {
                                        newText += line + "\n"
                                        channel.pushAsync("action_output", [
                                            "execution_id": executionId,
                                            "content": line
                                        ])
                                    }
                                }
                            )
                        } catch {
                            newText = "Error: \(error.localizedDescription)"
                        }

                        channel.pushAsync("action_result", [
                            "execution_id": executionId,
                            "result_text": newText
                        ])
                        // Stay blocked — wait for next continue or finish
                    }
                }

                executor.activeExecution?.finishHandler = {
                    channel.pushAsync("action_complete", [
                        "execution_id": executionId,
                        "status": "ok",
                        "result": ["text": lastText]
                    ])
                    Task { @MainActor in
                        executor.executionComplete(executionId: executionId, channel: channel)
                    }
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - CLI Argument Building

    /// Translates server payload into Claude CLI arguments.
    /// The client decides the exact CLI invocation — the server never
    /// sends shell commands.
    private func buildCLIArgs(
        messages: [[String: Any]],
        sessionId: String?,
        workingDir: String?,
        opts: [String: Any]
    ) -> [String] {
        // Implementation: build `claude` CLI command from messages,
        // --session-id, --working-dir, --max-turns, --add-dir, etc.
        // Details deferred to implementation phase.
        fatalError("TODO: implement CLI argument building")
    }

    private func buildResumeArgs(
        message: String,
        sessionId: String?,
        workingDir: String?
    ) -> [String] {
        // Implementation: build `claude --resume <session_id>` command
        // with the user's message piped via stdin or --message flag.
        // Details deferred to implementation phase.
        fatalError("TODO: implement CLI resume argument building")
    }

    private func sendError(
        executionId: String,
        reason: String,
        channel: PhoenixChannelLiveView,
        executor: NativeExecutor
    ) async {
        channel.pushAsync("action_complete", [
            "execution_id": executionId,
            "status": "error",
            "result": ["error": reason]
        ])
        await MainActor.run {
            executor.executionComplete(executionId: executionId, channel: channel)
        }
    }
}
#endif
```

### Git Action Handlers (design)

The three git action types follow the same pattern as pyre_client's `Actions.Git*` modules:

| Handler | What it does |
|---------|-------------|
| `GitPRSetupActionHandler` | Claude CLI call → parse shipping plan from output → `git checkout -b`, `git add`, `git commit`, `git push` via ShellExecutor → GitHub API to create draft PR → return `{text, branch_name, pr_url, pr_number}` |
| `GitShipActionHandler` | Claude CLI call → parse shipping plan → git operations → GitHub API to create PR (non-draft) → return `{text, shipping_summary}` |
| `GitReviewActionHandler` | Claude CLI call → parse verdict → fire-and-forget git + GitHub comment → return `{text, verdict}` |

All git operations use `ShellExecutor.run()` (non-streaming) to execute `git` commands locally. GitHub API calls use `URLSession`. The logic mirrors pyre_client's `Actions.Git` and `Actions.GitHub` modules but implemented in Swift.

**Implementation is deferred** — the handler protocol and routing are established now; individual handler implementations are built when pyre_native is ready to handle these action types.

---

## Change 6: Remove RemoteCommandService

`RemoteCommandService` and the `execute_commands` action type are removed entirely. `ShellExecutor` stays — it's the underlying subprocess engine used by action handlers.

### Files to remove

| File | Why |
|------|-----|
| `Services/RemoteCommandService.swift` | Replaced by NativeExecutor + action handlers. Arbitrary command execution is removed. |

### Files to add

| File | Purpose |
|------|---------|
| `Services/NativeExecutor.swift` | Action routing, capacity tracking, interactive loop infrastructure |
| `Services/Actions/PromptActionHandler.swift` | `"prompt"` action — Claude CLI subprocess |
| `Services/Actions/GitPRSetupActionHandler.swift` | `"git_pr_setup"` action — CLI + git + GitHub |
| `Services/Actions/GitShipActionHandler.swift` | `"git_ship"` action — CLI + git + GitHub |
| `Services/Actions/GitReviewActionHandler.swift` | `"git_review"` action — CLI + git + GitHub comment |
| `Protocols/NativeActionHandler.swift` | Protocol for action handler modules |

### Files to modify

| File | Change |
|------|--------|
| `Services/ConnectionPresenceService.swift` | Updated join payload, dispatch to NativeExecutor, register `action_continue`/`action_finish` handlers |
| `Views/Pages/HomeView.swift` | Replace `@ObservedObject remoteCommands` with `@ObservedObject executor: NativeExecutor` |

### Files unchanged

| File | Why |
|------|-----|
| `Services/ShellExecutor.swift` | Used by action handlers for CLI and git subprocess execution |
| `Models/ConnectionInfo.swift` | System info shape stays the same |
| `Services/Channels/*` | Channel infrastructure is correct as-is |

---

## Change 7: HomeView Updates

Replace `RemoteCommandService` observation with `NativeExecutor`.

### Before

```swift
#if os(macOS)
@ObservedObject private var remoteCommands = RemoteCommandService.shared
#endif

if let execution = remoteCommands.currentExecution { ... }
if remoteCommands.isRunning { Button("Stop") { remoteCommands.stop() } }
```

### After

```swift
#if os(macOS)
@ObservedObject private var executor = NativeExecutor.shared
#endif

if let execution = executor.activeExecution { ... }
if executor.isRunning { Button("Stop") { /* TODO: cancel active execution */ } }
```

The local command text field (manual shell execution for debugging) can stay as a local-only debug tool — it doesn't go through the server or NativeExecutor.

---

## Updated File Layout

```
Pyre/
├── Services/
│   ├── NativeExecutor.swift                 # NEW — action routing, capacity, interactive loop
│   ├── Actions/                             # NEW directory
│   │   ├── PromptActionHandler.swift        # NEW — "prompt" via Claude CLI
│   │   ├── GitPRSetupActionHandler.swift    # NEW — "git_pr_setup" via CLI + git
│   │   ├── GitShipActionHandler.swift       # NEW — "git_ship" via CLI + git
│   │   └── GitReviewActionHandler.swift     # NEW — "git_review" via CLI + git
│   ├── ShellExecutor.swift                  # UNCHANGED — subprocess engine
│   ├── ConnectionPresenceService.swift      # MODIFIED — join payload, event handlers
│   ├── Channels/                            # UNCHANGED
│   └── ...
├── Protocols/
│   ├── PageViewModel.swift                  # UNCHANGED
│   └── NativeActionHandler.swift            # NEW — action handler protocol
├── Models/
│   ├── ConnectionInfo.swift                 # UNCHANGED
│   └── Connections.swift                    # UNCHANGED
└── Views/
    └── Pages/
        └── HomeView.swift                   # MODIFIED — observe NativeExecutor
```

---

## Protocol Comparison: pyre_client vs pyre_native (After)

Both workers are peers from the server's perspective. Same action types, same wire format, same protocol.

| Aspect | pyre_client (Elixir) | pyre_native (Swift) |
|--------|---------------------|---------------------|
| **Join payload** | `{connection_id, status, available_capacity, backends, enabled_workflows, name}` | Same + system info (cpu, memory, os) |
| **Advertised backends** | `["claude_cli"]` or `["req_llm"]` etc. | `["claude_cli"]` (macOS) or `[]` (iOS) |
| **Action: prompt** | Elixir LLM backends (ClaudeCLI subprocess, ReqLLM API, AgenticLoop) | Claude CLI via ShellExecutor subprocess |
| **Action: git_pr_setup** | Elixir `System.cmd("git", ...)` + `Req` for GitHub API | `ShellExecutor.run("git ...")` + `URLSession` for GitHub API |
| **Action: git_ship** | Same as above | Same pattern, Swift implementation |
| **Action: git_review** | Same as above | Same pattern, Swift implementation |
| **action_output** | `{execution_id, content}` | `{execution_id, content}` |
| **action_result** | `{execution_id, result_text}` | `{execution_id, result_text}` |
| **action_complete** | `{execution_id, status, result}` | `{execution_id, status, result}` |
| **action_continue** | Resumes LLM session via Elixir backend | Resumes Claude CLI session via `--resume` |
| **action_finish** | Post-processing (git ops if git action) | Post-processing (git ops if git action) |
| **Interactive loop** | Executor GenServer `receive` loop | CheckedContinuation-based async blocking |
| **Session resume** | `--session-id` / `--resume` flags on CLI subprocess | Same flags, same CLI |
| **Tool execution** | `ReqLLM.Tool` structs → AgenticLoop (ReqLLM) or CLI-managed (ClaudeCLI) | CLI manages its own tool loop (`manages_tool_loop? = true` equivalent) |

### Key architectural parallel

Both clients follow the same decision tree for LLM execution:

```
payload received
  → extract messages, model_tier, role, session_id, interactive flag
  → resolve backend (pyre_client: from config; pyre_native: Claude CLI)
  → build CLI args from payload (both use --session-id, --working-dir, etc.)
  → spawn subprocess, stream output as action_output
  → if interactive: send action_result, block for continuation
  → if not interactive: send action_complete, free capacity
```

The implementations differ (Elixir GenServer vs Swift async/await) but the logic is identical.

---

## Server-Side Impact

### No server changes needed for pyre_native alignment

The server dispatches identical payloads to all workers. It already:
- Builds messages with personas (PLAN_08 `build_action_payload/8`)
- Includes `interactive` flag, `session_id`, `model_tier` in payload
- Routes actions by matching `backends` in Presence metadata

When pyre_native advertises `backends: ["claude_cli"]`, the server's `select_worker/1` treats it the same as a pyre_client worker advertising `"claude_cli"`.

### Payload key migration on server LiveViews

The server's LiveView components (`home_live.ex`, `connected_apps_list_live.ex`) currently read `payload["line"]` for `action_output`. Update to accept `"content"`:

```elixir
content = payload["content"] || payload["line"] || ""
```

This is backward compatible during the transition.

---

## What's Deferred

| Item | Status | Notes |
|------|--------|-------|
| `PromptActionHandler` implementation | **Design complete, implementation deferred** | CLI arg building, output parsing, session resume details |
| `GitPR*` / `GitShip` / `GitReview` handlers | **Design complete, implementation deferred** | Git operations via ShellExecutor, GitHub API via URLSession |
| iOS action support | **Future** | iOS has no CLI access. Could support notification or file-based actions. |
| Multiple backend support | **Future** | Currently Claude CLI only. Could add Cursor CLI, Codex CLI. |
| Command allowlists for git ops | **Future** | Git operations are hardcoded in handlers, not arbitrary. Low risk. |
| Capacity > 1 | **Future** | Infrastructure in place (NativeExecutor tracks active count). |

---

## Implementation Order

1. **Add `NativeActionHandler` protocol** — `Protocols/NativeActionHandler.swift`
2. **Add `NativeExecutor`** — `Services/NativeExecutor.swift` (routing, capacity, interactive loop infrastructure)
3. **Update `ConnectionPresenceService`** — New join payload fields, dispatch to NativeExecutor, register `action_continue`/`action_finish` handlers
4. **Add `PromptActionHandler` stub** — `Services/Actions/PromptActionHandler.swift` (compiles, routes correctly, returns "not yet implemented" error)
5. **Add `GitPRSetupActionHandler` / `GitShipActionHandler` / `GitReviewActionHandler` stubs** — Same pattern
6. **Update `HomeView`** — Observe NativeExecutor instead of RemoteCommandService
7. **Remove `RemoteCommandService`** — Fully replaced
8. **Update server LiveViews** — Accept `"content"` key in action_output alongside `"line"`
9. **Implement `PromptActionHandler`** — CLI arg building, subprocess streaming, session resume
10. **Implement git action handlers** — Git operations, GitHub API, response parsing
