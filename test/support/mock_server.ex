defmodule PyreClient.Test.MockServer do
  @moduledoc """
  A minimal Phoenix endpoint for testing PyreClient.Connection.
  Runs on a random port, speaks the pyre:* channel protocol.

  Usage from test setup:

      setup do
        %{url: url} = PyreClient.Test.MockServer.setup(self())
        ...
      end

  `setup/1` must be called from a test process (uses `start_supervised!`).
  """

  # Agent to share the test pid with the channel process
  defmodule TestPid do
    use Agent

    def start_link(_), do: Agent.start_link(fn -> nil end, name: __MODULE__)
    def set(pid), do: Agent.update(__MODULE__, fn _ -> pid end)
    def get, do: Agent.get(__MODULE__, & &1)
  end

  defmodule Endpoint do
    use Phoenix.Endpoint, otp_app: :pyre_client
    socket("/pyre", PyreClient.Test.MockServer.Socket, websocket: [connect_info: [:peer_data]])
  end

  defmodule Socket do
    use Phoenix.Socket
    channel("pyre:*", PyreClient.Test.MockServer.Channel)

    @impl true
    def connect(params, socket, _connect_info) do
      {:ok, assign(socket, :connection_id, params["connection_id"] || "test")}
    end

    @impl true
    def id(socket), do: "test_socket:#{socket.assigns.connection_id}"
  end

  defmodule Channel do
    use Phoenix.Channel

    def join("pyre:connections", params, socket) do
      send(self(), :after_join)

      if pid = PyreClient.Test.MockServer.TestPid.get() do
        send(pid, {:channel_joined, params})
      end

      {:ok, %{message: "connected"}, socket}
    end

    def handle_in("action_output", payload, socket) do
      if pid = PyreClient.Test.MockServer.TestPid.get(), do: send(pid, {:action_output, payload})
      {:noreply, socket}
    end

    def handle_in("action_result", payload, socket) do
      if pid = PyreClient.Test.MockServer.TestPid.get(), do: send(pid, {:action_result, payload})
      {:noreply, socket}
    end

    def handle_in("action_complete", payload, socket) do
      if pid = PyreClient.Test.MockServer.TestPid.get(),
        do: send(pid, {:action_complete, payload})

      {:noreply, socket}
    end

    def handle_in("update_metadata", payload, socket) do
      if pid = PyreClient.Test.MockServer.TestPid.get(),
        do: send(pid, {:update_metadata, payload})

      {:reply, :ok, socket}
    end

    def handle_info(:after_join, socket), do: {:noreply, socket}
  end

  @doc """
  Returns a port number and child specs for the mock server.
  Must be called from a test process that uses `start_supervised!`.
  """
  def port_and_specs(test_pid) do
    port = Enum.random(50_000..59_999)

    Application.put_env(:pyre_client, Endpoint,
      http: [port: port],
      server: true,
      adapter: Bandit.PhoenixAdapter,
      pubsub_server: PyreClient.Test.PubSub
    )

    specs = [
      {Phoenix.PubSub, name: PyreClient.Test.PubSub},
      TestPid,
      Endpoint
    ]

    %{port: port, url: "ws://localhost:#{port}/pyre/websocket", specs: specs, test_pid: test_pid}
  end
end
