defmodule PyreClient.Config do
  @moduledoc """
  Unified configuration for pyre_client.

  ## Static helpers

  Connection settings read from application env:

      PyreClient.Config.server_url()
      PyreClient.Config.available_capacity()

  ## Overridable callbacks

  Backend and action configuration delegates to `config_module/0`:

      PyreClient.Config.list_backends()
      PyreClient.Config.default_backend()
      PyreClient.Config.list_actions()
      PyreClient.Config.resolve_action("prompt")
      PyreClient.Config.resolve_model("standard", backend)

  ## Custom overrides

      defmodule MyApp.PyreClientConfig do
        use PyreClient.Config

        @impl PyreClient.Config
        def list_backends do
          PyreClient.Config.included_backends() ++ [
            %{module: MyApp.LLM.Ollama, name: "ollama",
              label: "Ollama", description: "Local Ollama"}
          ]
        end
      end

      config :pyre_client, config: MyApp.PyreClientConfig
  """

  # --- Overridable callbacks ---

  @callback list_backends() :: [map()]
  @callback default_backend() :: module()
  @callback list_actions() :: [map()]
  @callback resolve_action(String.t()) :: {:ok, module()} | :error
  @callback resolve_model(String.t(), module()) :: String.t()

  @optional_callbacks [
    list_backends: 0,
    default_backend: 0,
    list_actions: 0,
    resolve_action: 1,
    resolve_model: 2
  ]

  defmacro __using__(_opts) do
    quote do
      @behaviour PyreClient.Config
    end
  end

  @doc "Returns the configured override module, or this module as default."
  def config_module do
    Application.get_env(:pyre_client, :config, __MODULE__)
  end

  # --- Callback delegates ---

  def list_backends do
    mod = config_module()

    if mod != __MODULE__ and function_exported?(mod, :list_backends, 0) do
      mod.list_backends()
    else
      included_backends()
    end
  end

  def default_backend do
    mod = config_module()

    if mod != __MODULE__ and function_exported?(mod, :default_backend, 0) do
      mod.default_backend()
    else
      default_backend_impl()
    end
  end

  def list_actions do
    mod = config_module()

    if mod != __MODULE__ and function_exported?(mod, :list_actions, 0) do
      mod.list_actions()
    else
      included_actions()
    end
  end

  def resolve_action(action_type) do
    mod = config_module()

    if mod != __MODULE__ and function_exported?(mod, :resolve_action, 1) do
      mod.resolve_action(action_type)
    else
      resolve_action_impl(action_type)
    end
  end

  def resolve_model(tier, backend) do
    mod = config_module()

    if mod != __MODULE__ and function_exported?(mod, :resolve_model, 2) do
      mod.resolve_model(tier, backend)
    else
      resolve_model_impl(tier, backend)
    end
  end

  # --- Built-in defaults (non-overridable, used by custom configs to extend) ---

  @doc "Built-in LLM backends. Use in custom configs to extend rather than replace."
  def included_backends do
    [
      %{
        module: PyreClient.LLM.ReqLLM,
        name: "req_llm",
        label: "ReqLLM",
        description: "API-based LLM calls via ReqLLM"
      },
      %{
        module: PyreClient.LLM.ClaudeCLI,
        name: "claude_cli",
        label: "Claude CLI",
        description: "Claude Code CLI subprocess"
      },
      %{
        module: PyreClient.LLM.CursorCLI,
        name: "cursor_cli",
        label: "Cursor CLI",
        description: "Cursor Agent CLI subprocess"
      },
      %{
        module: PyreClient.LLM.CodexCLI,
        name: "codex_cli",
        label: "Codex CLI",
        description: "OpenAI Codex CLI subprocess"
      }
    ]
  end

  @doc "Built-in action types. Use in custom configs to extend rather than replace."
  def included_actions do
    [
      %{
        module: PyreClient.Actions.Prompt,
        name: "prompt",
        label: "Prompt",
        description: "Generic LLM prompt execution"
      },
      %{
        module: PyreClient.Actions.GitPRSetup,
        name: "git_pr_setup",
        label: "Git PR Setup",
        description: "LLM -> parse -> git -> draft GitHub PR"
      },
      %{
        module: PyreClient.Actions.GitShip,
        name: "git_ship",
        label: "Git Ship",
        description: "LLM -> parse -> git -> GitHub PR"
      },
      %{
        module: PyreClient.Actions.GitReview,
        name: "git_review",
        label: "Git Review",
        description: "LLM -> parse verdict -> git -> GitHub comment"
      },
      %{
        module: PyreClient.Actions.Reserve,
        name: "reserve",
        label: "Reserve",
        description: "Capacity reservation for workflow execution"
      }
    ]
  end

  # --- Default callback implementations ---

  defp default_backend_impl do
    case Application.get_env(:pyre_client, :llm_backend) do
      :claude_cli -> PyreClient.LLM.ClaudeCLI
      :cursor_cli -> PyreClient.LLM.CursorCLI
      :codex_cli -> PyreClient.LLM.CodexCLI
      :req_llm -> PyreClient.LLM.ReqLLM
      nil -> PyreClient.LLM.ReqLLM
      module when is_atom(module) -> module
    end
  end

  defp resolve_action_impl(action_type) do
    case Enum.find(included_actions(), &(&1.name == action_type)) do
      %{module: module} -> {:ok, module}
      nil -> :error
    end
  end

  @default_model_aliases %{
    "fast" => "anthropic:claude-haiku-4-5",
    "standard" => "anthropic:claude-sonnet-4-20250514",
    "advanced" => "anthropic:claude-opus-4-20250514"
  }

  defp resolve_model_impl(tier, _backend) when is_binary(tier) do
    aliases = Application.get_env(:pyre_client, :model_aliases, @default_model_aliases)
    Map.get(aliases, tier, tier)
  end

  defp resolve_model_impl(nil, _backend), do: resolve_model_impl("standard", nil)

  # --- Static helpers (not overridable) ---

  def server_url do
    Application.get_env(:pyre_client, :server_url, "ws://localhost:4000/websocket")
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
    list_backends() |> Enum.map(& &1.name)
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

  def service_token do
    Application.get_env(:pyre_client, :service_token)
  end

  defp generate_connection_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp default_name do
    {:ok, hostname} = :inet.gethostname()
    to_string(hostname)
  end
end
