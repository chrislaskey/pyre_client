# Pyre Client

Execution layer and thin WebSocket client for [Pyre](https://github.com/chrislaskey/pyre).

Pyre Client connects to a Pyre Web server as a worker, receives dispatched
actions, executes them locally (LLM calls, git operations, GitHub API), and
streams results back. It owns all LLM backends, the tool system, the agentic
loop, and session management.

> For a fully configured standalone application see [Pyre App](https://github.com/chrislaskey/pyre_app)

## Installation

Add `pyre_client` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:pyre_client, git: "https://github.com/chrislaskey/pyre_client", branch: "main"}
  ]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

## Configuration

### Server URL

Point the client at your Pyre Web server:

```elixir
# config/runtime.exs
config :pyre_client,
  server_url: System.get_env("PYRE_SERVER_URL", "ws://localhost:4000/websocket")
```

The WebSocket path must match the socket mount path in the host app's endpoint.
If the endpoint mounts `PyreWeb.Socket` at a subpath — e.g.,
`socket "/pyre", PyreWeb.Socket` — the `server_url` must include that prefix:
`ws://localhost:4000/pyre/websocket`.

### Worker Identity

Each client identifies itself when joining the server channel:

```elixir
# config/runtime.exs
config :pyre_client,
  connection_id: System.get_env("PYRE_CLIENT_CONNECTION_ID"),
  connection_name: System.get_env("PYRE_CLIENT_CONNECTION_NAME")
```

If not set, `connection_id` defaults to a random hex string and
`connection_name` defaults to the system hostname.

### Service Token

Authenticate with the server using a pre-shared service token:

```elixir
# config/runtime.exs
config :pyre_client,
  service_token: System.get_env("PYRE_CLIENT_WEBSOCKET_SERVICE_TOKEN")
```

Generate a token with `mix pyre.gen.token` (in the pyre_lib project). The
token is sent as an HTTP header on socket connect and in the channel join
payload — it never appears in the URL.

### LLM Backend

Select which LLM backend to use:

```elixir
# config/runtime.exs
config :pyre_client,
  llm_backend: :claude_cli
```

Available backends:

| Backend | Config key | Description |
|---------|-----------|-------------|
| `PyreClient.LLM.ReqLLM` | `:req_llm` | API-based (default) — any major provider via ReqLLM |
| `PyreClient.LLM.ClaudeCLI` | `:claude_cli` | Claude CLI subprocess |
| `PyreClient.LLM.CursorCLI` | `:cursor_cli` | Cursor CLI subprocess |
| `PyreClient.LLM.CodexCLI` | `:codex_cli` | OpenAI Codex CLI subprocess |

### API Keys

When using the `req_llm` backend, set at least one API key:

```bash
export ANTHROPIC_API_KEY=sk-ant-...
export OPENAI_API_KEY=sk-...
```

Model aliases map tiers to provider-specific model strings:

```elixir
# config/config.exs
config :pyre_client,
  model_aliases: %{
    "fast" => "anthropic:claude-haiku-4-5",
    "standard" => "anthropic:claude-sonnet-4-20250514",
    "advanced" => "anthropic:claude-opus-4-20250514"
  }
```

To use a different provider (e.g., OpenAI), change the model alias strings
and set the corresponding API key:

```elixir
config :pyre_client,
  model_aliases: %{
    "fast" => "openai:gpt-4o-mini",
    "standard" => "openai:gpt-4o",
    "advanced" => "openai:o1"
  }
```

### CLI Backends

CLI backends require their respective CLI tools installed and on PATH:

```bash
# Claude CLI
npm install -g @anthropic-ai/claude-code

# Cursor CLI (bundled with Cursor IDE)
# Ensure `cursor` is on PATH

# Codex CLI
npm install -g @openai/codex
```

### Workflow Filtering

By default, the client accepts actions from all workflow types. To restrict
to specific workflows:

```elixir
config :pyre_client,
  enabled_workflows: [:chat, :task]
```

An empty list (the default) accepts all workflows.

## Supervision Tree

Pyre Client is a library — it has no OTP application of its own. Add its
processes to your application's supervision tree:

```elixir
# lib/my_app/application.ex
children = [
  # ... existing children ...
  PyreClient.Session.Registry,
  PyreClient.Runner,
  PyreClient.Connection
]
```

| Child | Purpose |
|-------|---------|
| `PyreClient.Session.Registry` | Maps execution IDs to LLM session IDs for CLI session resumption |
| `PyreClient.Runner` | Receives action dispatches, routes to action modules, manages capacity |
| `PyreClient.Connection` | WebSocket client with keepalive, reconnection, and channel management |

Start order matters — Connection depends on Runner being available.

## Architecture

Pyre Client is the **execution layer**. It has no knowledge of workflows,
stages, or orchestration — that's [pyre_lib](https://github.com/chrislaskey/pyre_lib)'s
responsibility. The two libraries have no compile-time dependency on each other;
host apps compose both.

```
pyre_lib (orchestration + UI)               pyre_client (execution)
├── Pyre.Flows.*     (workflow pipelines)   ├── PyreClient.LLM.*     (all backends)
├── Pyre.Actions.*   (action definitions)   ├── PyreClient.Tools.*   (tool sandbox + agentic loop)
├── Pyre.RunServer   (run lifecycle)        ├── PyreClient.Session.* (session management)
├── Pyre.Config      (workflow config)      ├── PyreClient.Runner    (action execution)
├── PyreWeb.*        (UI, channels)         ├── PyreClient.Connection (WebSocket)
└── depends on: jido, jido_ai              └── depends on: req_llm, websockex
```

### Actions

The server dispatches named action types with data parameters — never shell
commands or arbitrary code. Each action module is a hardcoded implementation
that decides what to execute locally.

```
lib/pyre_client/actions/
  prompt.ex         # Generic LLM call (covers 9 of 11 server actions)
  git_pr_setup.ex   # LLM -> parse -> git -> draft GitHub PR
  git_ship.ex       # LLM -> parse -> git -> GitHub PR
  git_review.ex     # LLM -> parse verdict -> git -> GitHub comment
  llm.ex            # Shared LLM calling infrastructure
  git.ex            # Shared git operations and parsing utilities
  github.ex         # Lightweight GitHub API client
```

### LLM Backends

All LLM backends implement the `PyreClient.LLM` behaviour:

```
lib/pyre_client/llm/
  req_llm.ex     # API-based calls via ReqLLM hex package
  claude_cli.ex  # Claude Code CLI subprocess
  cursor_cli.ex  # Cursor Agent CLI subprocess
  codex_cli.ex   # OpenAI Codex CLI subprocess
  mock.ex        # Test mock using process dictionary
```

Backends that manage their own tool-calling loop (CLI backends) declare
`manages_tool_loop?() = true`. The Runner calls `chat/4` directly for these.
For ReqLLM, the Runner routes through `PyreClient.Tools.AgenticLoop`.

### Tools

Agents get sandboxed file and shell tools based on their role:

```
lib/pyre_client/tools.ex            # Tool definitions (read_file, write_file, list_directory, run_command)
lib/pyre_client/tools/agentic_loop.ex  # Multi-turn tool-use loop for ReqLLM backend
```

**Read-write roles**: Programmer, TestWriter, SoftwareEngineer, Generalist, PrototypeEngineer

**Read-only roles**: QAReviewer, Designer, ProductManager, Shipper, SoftwareArchitect

Tools include path traversal protection, command allowlist validation, and
output truncation at 10KB per response.

### WebSocket Protocol

The client speaks the Phoenix V2 channel wire format over WebSocket:

```
lib/pyre_client/protocol.ex    # Phoenix V2 wire protocol (pure encoder/decoder)
lib/pyre_client/connection.ex  # WebSockex client with ping/pong and reconnection
lib/pyre_client/channel.ex     # Channel state machine (disconnected -> joining -> joined)
```

Two levels of keepalive:

| Level | Interval | Purpose |
|-------|----------|---------|
| WebSocket Ping/Pong | 20s | Detects dead TCP connections |
| Phoenix Heartbeat | 30s | Prevents server-side channel timeout |

Reconnection uses linear backoff: 1s, 2s, 3s, ... capped at 30s.

## Customization

### Custom LLM backends

Implement the `PyreClient.LLM` behaviour. Use `use PyreClient.LLM` to get
the behaviour and a default `manages_tool_loop?/0` returning `false`:

```elixir
defmodule MyApp.LLM.Ollama do
  use PyreClient.LLM

  @impl true
  def generate(model, messages, opts \\ []) do
    # Call your LLM provider
    {:ok, "response text"}
  end

  @impl true
  def stream(model, messages, opts \\ []) do
    output_fn = Keyword.get(opts, :output_fn, &IO.write/1)
    # Stream tokens via output_fn, return full text
    {:ok, "response text"}
  end

  @impl true
  def chat(model, messages, tools, opts \\ []) do
    # Handle tool-use conversations
    {:ok, "response text"}
  end
end
```

Then register it via a custom config module:

```elixir
defmodule MyApp.PyreClientConfig do
  use PyreClient.Config

  @impl PyreClient.Config
  def list_backends do
    PyreClient.Config.included_backends() ++ [
      %{module: MyApp.LLM.Ollama, name: "ollama",
        label: "Ollama", description: "Local models via Ollama"}
    ]
  end

  @impl PyreClient.Config
  def default_backend, do: MyApp.LLM.Ollama
end
```

```elixir
# config/config.exs
config :pyre_client, config: MyApp.PyreClientConfig
```

For CLI-style backends that manage their own tool-calling loop, override
`manages_tool_loop?/0` to return `true`. This tells the Runner to call
`chat/4` directly instead of routing through the agentic loop.

### Custom action types

Implement the `PyreClient.Actions` callback and register via config:

```elixir
defmodule MyApp.Actions.Deploy do
  @behaviour PyreClient.Actions

  @impl true
  def execute(payload, context) do
    # Custom action logic
    {:ok, %{text: "Deployed successfully"}}
  end
end
```

```elixir
defmodule MyApp.PyreClientConfig do
  use PyreClient.Config

  @impl PyreClient.Config
  def list_actions do
    PyreClient.Config.included_actions() ++ [
      %{module: MyApp.Actions.Deploy, name: "deploy",
        label: "Deploy", description: "Custom deploy action"}
    ]
  end
end
```

### Overridable config callbacks

The `PyreClient.Config` module supports these overridable callbacks:

| Callback | Default | Description |
|----------|---------|-------------|
| `list_backends/0` | Built-in 4 backends | Available LLM backends |
| `default_backend/0` | From `:llm_backend` config | Default LLM backend module |
| `list_actions/0` | Built-in 4 action types | Available action types |
| `resolve_action/1` | Lookup by name | Map action type string to module |
| `resolve_model/2` | From `:model_aliases` config | Map tier string to model string |

## Testing

Actions and backends are testable without LLM calls using the mock:

```elixir
# Test a single action
Process.put(:mock_llm_response, "APPROVE\n\nLooks great!")
{:ok, result} = PyreClient.Actions.Prompt.execute(payload, %{
  backend: PyreClient.LLM.Mock,
  model: "test",
  tools: [],
  execution_id: "test-1",
  opts: [streaming: false],
  output_fn: fn _ -> :ok end,
  send_to_server: fn _, _ -> :ok end,
  interactive?: false
})

# Sequence multiple mock responses
Process.put(:mock_llm_responses, ["First response", "Second response"])
```

The mock backend uses process dictionary storage, so tests must use
`async: false`.
