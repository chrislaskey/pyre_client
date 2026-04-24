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

  When true, the Runner calls `chat/4` directly with tools.
  When false, the Runner routes through `PyreClient.Tools.AgenticLoop`.
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
