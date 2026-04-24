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
        server_url: "ws://localhost:4000/websocket",
        connection_id: "my-worker",
        available_capacity: 1,
        llm_backend: :claude_cli

  Start in your supervision tree:

      children = [
        PyreClient.Session.Registry,
        PyreClient.Runner,
        PyreClient.Connection
      ]
  """

  @doc "Returns the current connection status."
  defdelegate status(), to: PyreClient.Connection

  @doc "Updates worker metadata (capacity, status, etc.)."
  defdelegate update_metadata(metadata), to: PyreClient.Connection
end
