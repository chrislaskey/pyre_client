# Stage 2 — Project Structure

## Design Principle

`pyre_client` is the **execution layer** for the Pyre platform. It owns all LLM backends, the tool system, the agentic loop, session management, git operations, and GitHub API interactions. It connects to a Pyre Web server as a worker, receives named action types (`prompt`, `git_pr_setup`, `git_ship`, `git_review`), and executes the full action lifecycle locally.

It has **no dependency on pyre_lib** — they are independent peer libraries composed by the host app. pyre_client depends on `req_llm` directly (no jido transitive dependency).

No OTP application module, no auto-start. The host app adds it as a dependency, configures it, and starts the processes in their own supervision tree.

## File Layout

```
pyre_client/
├── mix.exs
├── lib/
│   ├── pyre_client.ex                 # Public API (WebSocket client)
│   ├── pyre_client/
│   │   ├── connection.ex              # WebSockex client (Stage 4)
│   │   ├── channel.ex                 # Channel protocol layer (Stage 5)
│   │   ├── protocol.ex                # Phoenix V2 wire encoding/decoding (Stage 3)
│   │   ├── executor.ex                # Action execution + output streaming (Stage 6)
│   │   ├── config.ex                  # Client configuration
│   │   ├── llm.ex                     # PyreClient.LLM behaviour
│   │   ├── llm/
│   │   │   ├── config.ex              # PyreClient.LLM.Config — backend listing/resolution
│   │   │   ├── req_llm.ex             # PyreClient.LLM.ReqLLM
│   │   │   ├── claude_cli.ex          # PyreClient.LLM.ClaudeCLI
│   │   │   ├── cursor_cli.ex          # PyreClient.LLM.CursorCLI
│   │   │   ├── codex_cli.ex           # PyreClient.LLM.CodexCLI
│   │   │   └── mock.ex                # PyreClient.LLM.Mock
│   │   ├── tools.ex                   # PyreClient.Tools — tool definitions for ReqLLM
│   │   ├── tools/
│   │   │   └── agentic_loop.ex        # PyreClient.Tools.AgenticLoop — multi-turn tool loop
│   │   ├── actions.ex                 # PyreClient.Actions — behaviour + routing registry
│   │   ├── actions/
│   │   │   ├── prompt.ex              # PyreClient.Actions.Prompt — LLM call → return text
│   │   │   ├── git_pr_setup.ex        # PyreClient.Actions.GitPRSetup — LLM → parse → git → draft PR
│   │   │   ├── git_ship.ex            # PyreClient.Actions.GitShip — LLM → parse → git → PR
│   │   │   ├── git_review.ex          # PyreClient.Actions.GitReview — LLM → parse verdict → git → comment
│   │   │   ├── git.ex                 # PyreClient.Actions.Git — shared git/parsing utilities
│   │   │   └── github.ex              # PyreClient.Actions.GitHub — lightweight GitHub API client
│   │   └── session/
│   │       ├── session.ex             # PyreClient.Session — connection ID generation only
│   │       └── registry.ex            # PyreClient.Session.Registry — maps execution_id → session_id from server payloads
└── test/
    ├── test_helper.exs
    ├── pyre_client/
    │   ├── connection_test.exs
    │   ├── channel_test.exs
    │   ├── protocol_test.exs
    │   ├── executor_test.exs
    │   ├── tools_test.exs
    │   ├── actions_test.exs
    │   ├── actions/
    │   │   ├── prompt_test.exs
    │   │   ├── git_pr_setup_test.exs
    │   │   ├── git_ship_test.exs
    │   │   ├── git_review_test.exs
    │   │   └── git_test.exs
    │   └── llm/
    │       ├── config_test.exs
    │       ├── claude_cli_test.exs
    │       └── mock_test.exs
    └── support/
        └── mock_server.ex              # Test WebSocket server
```

All modules live under the `PyreClient.*` namespace.

## mix.exs

```elixir
defmodule PyreClient.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/chrislaskey/pyre_client"

  def project do
    [
      app: :pyre_client,
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Execution layer and thin WebSocket client for Pyre",
      package: package(),
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # LLM API client — direct dep, NO jido transitive dependency
      # Used by ReqLLM backend, AgenticLoop, and tool type definitions
      {:req_llm, "~> 1.9"},

      # WebSocket client
      {:websockex, "~> 0.5", git: "https://github.com/dominicletz/websockex"},

      # JSON encoding (also pulled in by req_llm, but explicit for clarity)
      {:jason, "~> 1.2"},

      # Testing
      {:bandit, "~> 1.5", only: :test},
      {:phoenix, "~> 1.8", only: :test}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE)
    ]
  end
end
```

### Dependency Rationale

| Dep | Why | What we use |
|-----|-----|-------------|
| `req_llm` | LLM HTTP client, tool types, response classification | `ReqLLM.generate_text/3`, `ReqLLM.stream_text/3`, `ReqLLM.Context`, `ReqLLM.Response`, `ReqLLM.Tool`, `ReqLLM.ToolCall` |
| `websockex` | OTP-compatible WebSocket client | Connection lifecycle, ping/pong |
| `jason` | JSON encoding/decoding | Phoenix Channel V2 protocol, CLI backend output parsing |
| `req` | HTTP client (transitive via req_llm, explicit for clarity) | GitHub API calls in git action modules (`Actions.GitHub`) |
| `bandit` + `phoenix` | Test-only | Spin up a real Phoenix endpoint for integration tests |

**Why `req_llm`?** Three reasons:
1. `PyreClient.LLM.ReqLLM` backend wraps `ReqLLM.generate_text/3` and `ReqLLM.stream_text/3`
2. `PyreClient.Tools` defines tools as `ReqLLM.Tool` structs (with callbacks for file I/O and command execution)
3. `PyreClient.Tools.AgenticLoop` uses `ReqLLM.Response.classify/1`, `ReqLLM.Context.append/2`, and `ReqLLM.Tool.execute/2`

**Why not `jido_ai`?** `req_llm` has zero dependency on `jido`. The chain is `jido_ai → jido + req_llm`. By depending on `req_llm` directly, workers get full LLM capability without any workflow machinery.

**No dependency on `pyre_lib`.** pyre_client and pyre_lib are independent peer libraries.

## Configuration

### Client Configuration (`:pyre_client` namespace)

| Key | Default | Description |
|-----|---------|-------------|
| `server_url` | `"ws://localhost:4000/pyre/websocket"` | Pyre Web server WebSocket URL |
| `connection_id` | auto-generated | Unique worker ID for presence tracking |
| `connection_name` | hostname | Human-readable name shown in Pyre Web UI |
| `available_capacity` | `1` | Max concurrent actions |
| `enabled_workflows` | `[]` (all) | Workflow types to accept (empty = all) |
| `ping_interval_ms` | `20_000` | WebSocket-level ping interval |
| `heartbeat_interval_ms` | `30_000` | Phoenix heartbeat interval |
| `llm_backend` | `:req_llm` | Default LLM backend atom |
| `llm_config` | `PyreClient.LLM.Config` | Config module for backend listing |
| `claude_cli_executable` | `"claude"` | Path to Claude CLI binary |
| `cursor_cli_executable` | `"cursor-agent"` | Path to Cursor CLI binary |
| `codex_cli_executable` | `"codex"` | Path to Codex CLI binary |

### Backend Advertisement

The client advertises its available LLM backends in Presence metadata. Host app worker selectors (e.g., pyre_app's `WorkflowJob.select_worker/1`) filter workers by backend compatibility.

```elixir
backends = PyreClient.LLM.Config.list_backends() |> Enum.map(& &1.name)
# => ["req_llm", "claude_cli", "cursor_cli", "codex_cli"]
```

### Example Host App Configuration

```elixir
# config/config.exs — LLM backend selection
config :pyre_client,
  llm_backend: :claude_cli

# config/runtime.exs — client connection settings + API keys
config :pyre_client,
  server_url: System.get_env("PYRE_SERVER_URL", "ws://localhost:4000/pyre/websocket"),
  connection_id: System.get_env("PYRE_CONNECTION_ID", "worker-1"),
  connection_name: System.get_env("PYRE_CONNECTION_NAME", "my-build-server"),
  available_capacity: 1,
  enabled_workflows: []
```

### Custom Backend Registration

```elixir
defmodule MyApp.LLMConfig do
  use PyreClient.LLM.Config

  @impl PyreClient.LLM.Config
  def list_backends do
    PyreClient.LLM.Config.included_backends() ++ [
      %{
        module: MyApp.LLM.CustomBackend,
        name: "custom_backend",
        label: "My Custom Backend",
        description: "Custom LLM integration"
      }
    ]
  end
end

# config/config.exs
config :pyre_client, llm_config: MyApp.LLMConfig
```

## Config Module: `PyreClient.Config`

```elixir
defmodule PyreClient.Config do
  @moduledoc """
  Reads PyreClient connection configuration from application env.
  """

  def server_url do
    Application.get_env(:pyre_client, :server_url, "ws://localhost:4000/pyre/websocket")
  end

  def connection_id do
    Application.get_env(:pyre_client, :connection_id) || generate_connection_id()
  end

  def connection_name do
    Application.get_env(:pyre_client, :connection_name) || default_name()
  end

  def available_capacity do
    Application.get_env(:pyre_client, :available_capacity, 1)
  end

  def backends do
    PyreClient.LLM.Config.list_backends() |> Enum.map(& &1.name)
  end

  def enabled_workflows do
    Application.get_env(:pyre_client, :enabled_workflows, [])
  end

  def ping_interval_ms do
    Application.get_env(:pyre_client, :ping_interval_ms, 20_000)
  end

  def heartbeat_interval_ms do
    Application.get_env(:pyre_client, :heartbeat_interval_ms, 30_000)
  end

  def resolve_backend do
    PyreClient.LLM.Config.default_backend()
  end

  defp generate_connection_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp default_name do
    {:ok, hostname} = :inet.gethostname()
    to_string(hostname)
  end
end
```

## LLM Behaviour: `PyreClient.LLM`

The canonical LLM behaviour — moved from pyre_lib's `Pyre.LLM`. Uses `ReqLLM` types since pyre_client depends on `req_llm` directly.

```elixir
defmodule PyreClient.LLM do
  @moduledoc """
  LLM behaviour for pyre_client backends.

  ## Built-in implementations

  - `PyreClient.LLM.ReqLLM` — API-based (default), uses ReqLLM
  - `PyreClient.LLM.ClaudeCLI` — Claude CLI subprocess
  - `PyreClient.LLM.CursorCLI` — Cursor CLI subprocess
  - `PyreClient.LLM.CodexCLI` — Codex CLI subprocess
  - `PyreClient.LLM.Mock` — test mock

  ## Custom backends

      defmodule MyApp.LLM.Ollama do
        use PyreClient.LLM

        @impl true
        def generate(model, messages, opts), do: ...
        @impl true
        def stream(model, messages, opts), do: ...
        @impl true
        def chat(model, messages, tools, opts), do: ...
      end
  """

  @type message :: %{role: :system | :user | :assistant, content: String.t() | [map()]}
  @type model :: String.t()

  @callback generate(model(), [message()], keyword()) ::
              {:ok, String.t()} | {:error, term()}

  @callback stream(model(), [message()], keyword()) ::
              {:ok, String.t()} | {:error, term()}

  @doc """
  Calls the LLM with tool support.

  ReqLLM-backed implementations return `ReqLLM.Response.t()`.
  CLI backends return plain `String.t()` (they manage their own tool loop).
  """
  @callback chat(model(), [message()] | ReqLLM.Context.t(), [ReqLLM.Tool.t()], keyword()) ::
              {:ok, ReqLLM.Response.t() | String.t()} | {:error, term()}

  @doc """
  Returns true if this backend manages its own tool-use loop internally.

  When true, the Executor calls `chat/4` directly with tools.
  When false, the Executor routes through `PyreClient.Tools.AgenticLoop`.
  """
  @callback manages_tool_loop?() :: boolean()

  @optional_callbacks [manages_tool_loop?: 0]

  defmacro __using__(_opts) do
    quote do
      @behaviour PyreClient.LLM

      @impl PyreClient.LLM
      def manages_tool_loop?, do: false
      defoverridable manages_tool_loop?: 0
    end
  end
end
```

## LLM Config Module: `PyreClient.LLM.Config`

```elixir
defmodule PyreClient.LLM.Config do
  @moduledoc """
  LLM backend configuration and resolution.

  Host apps can override by implementing the callbacks and
  configuring `config :pyre_client, llm_config: MyApp.LLMConfig`.
  """

  @callback list_backends() :: [map()]
  @callback default_backend() :: module()

  defmacro __using__(_opts) do
    quote do
      @behaviour PyreClient.LLM.Config
    end
  end

  def config_module do
    Application.get_env(:pyre_client, :llm_config, __MODULE__)
  end

  def list_backends do
    config_module().list_backends()
  end

  @doc """
  Returns the backend module configured for this client deployment.

  The server does NOT specify which backend to use — each client
  deployment is configured with its own backend via
  `config :pyre_client, llm_backend: :claude_cli`. The server only
  sends the model tier; the client resolves both backend and model.
  """
  def default_backend do
    config_module().default_backend()
  end

  def included_backends do
    [
      %{module: PyreClient.LLM.ReqLLM, name: "req_llm",
        label: "ReqLLM", description: "API-based LLM calls via ReqLLM"},
      %{module: PyreClient.LLM.ClaudeCLI, name: "claude_cli",
        label: "Claude CLI", description: "Claude Code CLI subprocess"},
      %{module: PyreClient.LLM.CursorCLI, name: "cursor_cli",
        label: "Cursor CLI", description: "Cursor Agent CLI subprocess"},
      %{module: PyreClient.LLM.CodexCLI, name: "codex_cli",
        label: "Codex CLI", description: "OpenAI Codex CLI subprocess"}
    ]
  end

  # --- Model tier resolution ---
  # The server sends a tier string ("fast", "standard", "advanced").
  # The client resolves it to a backend-specific model string locally.

  @default_model_aliases %{
    "fast" => "anthropic:claude-haiku-4-5",
    "standard" => "anthropic:claude-sonnet-4-20250514",
    "advanced" => "anthropic:claude-opus-4-20250514"
  }

  @doc """
  Resolves a model tier string to a concrete model identifier.

  The server sends tier names ("fast", "standard", "advanced") in
  action payloads. Each client resolves them to backend-appropriate
  model strings. CLI backends further map these internally (e.g.,
  ClaudeCLI maps "anthropic:claude-haiku-4-5" → "haiku").

  Override via `config :pyre_client, :model_aliases, %{...}`.
  """
  def resolve_model(tier, _backend) when is_binary(tier) do
    aliases = Application.get_env(:pyre_client, :model_aliases, @default_model_aliases)
    Map.get(aliases, tier, tier)
  end

  def resolve_model(nil, _backend), do: resolve_model("standard", nil)

  # Default callback implementations

  def list_backends(_), do: included_backends()

  def default_backend(_) do
    case Application.get_env(:pyre_client, :llm_backend) do
      :claude_cli -> PyreClient.LLM.ClaudeCLI
      :cursor_cli -> PyreClient.LLM.CursorCLI
      :codex_cli -> PyreClient.LLM.CodexCLI
      :req_llm -> PyreClient.LLM.ReqLLM
      nil -> PyreClient.LLM.ReqLLM
      module when is_atom(module) -> module
    end
  end
end
```

## Public API Module

```elixir
defmodule PyreClient do
  @moduledoc """
  Execution layer and thin WebSocket client for Pyre.

  Connects to a Pyre Web server over WebSocket, registers as a worker,
  and executes dispatched LLM prompt actions. A thin client with no
  knowledge of workflows or orchestration.

  Owns all LLM backends, the tool system, the agentic loop, and session
  management. Independent of pyre_lib — no compile-time dependency.

  ## Usage

      {:pyre_client, git: "https://github.com/chrislaskey/pyre_client", branch: "main"}

  Configure:

      config :pyre_client,
        server_url: "ws://localhost:4000/pyre/websocket",
        connection_id: "my-worker",
        available_capacity: 1,
        llm_backend: :claude_cli

  Start in your supervision tree:

      children = [
        PyreClient.Session.Registry,
        PyreClient.Executor,
        PyreClient.Connection
      ]
  """

  @doc "Returns the current connection status."
  defdelegate status(), to: PyreClient.Connection

  @doc "Updates worker metadata (capacity, status, etc.)."
  defdelegate update_metadata(metadata), to: PyreClient.Connection
end
```

## Host App Integration

### As a standalone thin client

```elixir
# my_pyre_worker/mix.exs
defp deps do
  [
    {:pyre_client, git: "https://github.com/chrislaskey/pyre_client", branch: "main"}
  ]
end

# my_pyre_worker/lib/my_pyre_worker/application.ex
def start(_type, _args) do
  children = [
    PyreClient.Executor,
    PyreClient.Connection
  ]

  Supervisor.start_link(children, strategy: :one_for_one)
end
```

No `jido`, no workflow engine, no RunServer — just WebSocket + LLM backends + tools.

### Embedded in pyre_app (alongside pyre_lib)

```elixir
# pyre_app/mix.exs — depends on BOTH pyre_lib and pyre_client
defp deps do
  [
    {:pyre, path: "../pyre_lib"},           # Orchestration + UI
    {:pyre_client, path: "../pyre_client"}, # Local worker execution
    # ...
  ]
end

# pyre_app/lib/app/application.ex — add client to children
children = [
  # ... pyre_lib children (RunServer, etc.) ...
  PyreClient.Session.Registry,
  PyreClient.Executor,
  PyreClient.Connection
]

# pyre_app/config/runtime.exs
config :pyre_client,
  server_url: "ws://localhost:#{System.get_env("PORT", "4000")}/pyre/websocket",
  connection_id: "local-worker",
  connection_name: "local",
  available_capacity: 1,
  llm_backend: :claude_cli
```

When embedded in pyre_app, the client connects to the same server via localhost WebSocket. pyre_lib and pyre_client are in the same BEAM VM but have no compile-time coupling.
