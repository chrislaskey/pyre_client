# Client Resume V2: Graceful Fallback for Lost Session Mappings

## What Was Done

Implemented graceful handling of `action_continue` and `action_finish` for execution_ids the client doesn't recognize (e.g., after a client restart). Two code changes: one in `pyre_client/runner.ex`, one in `pyre_lib/flows/dispatch.ex`.

### Changes

**`handle_continue` for unknown execution** — Instead of silently dropping the message, the Runner now spawns a recovery session: generates a new session ID, builds a context with the user's message + a "resumed conversation" note, and starts a full interactive session (with tools, working_dir, streaming) via the same `start_interactive_session` path used by normal actions. The note tells the LLM it lost session context, to inspect local/remote state, share what it knows, and ask clarifying questions.

**`handle_finish` for unknown execution** — Instead of silently dropping, sends `action_complete` ack back to the server so the server-side `receive_action_result` doesn't hang.

**DRY refactor** — Renamed `execute_interactive` to `start_interactive_session` with a doc comment explaining it's the shared entry point for both normal action dispatch and recovery. No behavior change.

**Server-side: `working_dir` in `action_continue`** — Added `context.working_dir` to the `action_continue` PubSub payload so the client can run the recovery session in the correct directory with tools available.

## Files Created

- `pyre_client/priv/pyre/features/client-resume-v2/plan.md` — Implementation plan
- `pyre_client/priv/pyre/features/client-resume-v2/20260430_221836/01_generalist_output.md` — This summary

## Files Modified

- `pyre_client/lib/pyre_client/runner.ex` — Recovery session logic, handle_finish ack, DRY refactor
- `pyre_lib/lib/pyre/flows/dispatch.ex` — Include `working_dir` in `action_continue` payload

## Verification

- `pyre_client`: **78 tests, 0 failures** — all pass
- `pyre_lib`: **411 tests, 0 failures** (1 flaky LiveView test fails intermittently in the full suite but passes in isolation; pre-existing, unrelated)
- Both projects compile with `--warnings-as-errors`

## Notes

- The recovery session uses the `:generalist` role (full tools: Bash, Read, Edit, Write, Glob, Grep) and standard model tier by default — this gives the LLM full capability to inspect the codebase and pick up context.
- The resumed-conversation note is intentionally direct: tell the user what you know, ask for what you don't. No over-engineering.
- Subsequent `action_continue` / `action_finish` messages for the same execution_id work normally because the recovery execution is registered in `active_executions` and enters the standard `interactive_loop`.
