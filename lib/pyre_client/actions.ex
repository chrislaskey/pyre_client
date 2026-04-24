defmodule PyreClient.Actions do
  @moduledoc """
  Action behaviour and routing registry.

  Each action type has a dedicated module that implements the full
  execution lifecycle. The Runner routes to the correct module
  via `resolve/1`.

  ## Security Model

  The server sends named action types with data parameters — never
  shell commands or arbitrary code. Each action module is a hardcoded
  implementation that decides what to execute locally.
  """

  @type execution_context :: %{
          execution_id: String.t(),
          backend: module(),
          model: String.t(),
          tools: [ReqLLM.Tool.t()],
          opts: keyword(),
          output_fn: (String.t() -> :ok),
          send_to_server: (String.t(), map() -> :ok),
          interactive?: boolean()
        }

  @doc """
  Execute the action. Returns `{:ok, result_map}` or `{:error, reason}`.
  """
  @callback execute(payload :: map(), context :: execution_context()) ::
              {:ok, map()} | {:error, term()}

  # --- Routing (delegates to Config) ---

  @doc "List all registered action types."
  defdelegate list_actions(), to: PyreClient.Config

  @doc "Resolve an action type string to its implementation module."
  defdelegate resolve(action_type), to: PyreClient.Config, as: :resolve_action
end
