defmodule PyreClient.ConnectionTest do
  use ExUnit.Case, async: false

  alias PyreClient.Test.MockServer

  setup do
    %{url: url, specs: specs, test_pid: _} = MockServer.port_and_specs(self())

    for spec <- specs do
      start_supervised!(spec)
    end

    MockServer.TestPid.set(self())

    Application.put_env(:pyre_client, :server_url, url)

    Application.put_env(
      :pyre_client,
      :connection_id,
      "test-#{System.unique_integer([:positive])}"
    )

    # Start Runner since Channel delegates to it
    start_supervised!(PyreClient.Runner)

    on_exit(fn ->
      try do
        GenServer.stop(PyreClient.Connection)
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  test "connects and joins pyre:connections" do
    {:ok, _pid} = PyreClient.Connection.start_link()

    assert_receive {:channel_joined, params}, 5_000
    assert params["status"] == "active"
    assert is_integer(params["available_capacity"])
    assert is_list(params["backends"])
  end

  test "sends heartbeats and stays alive" do
    Application.put_env(:pyre_client, :heartbeat_interval_ms, 100)
    {:ok, _pid} = PyreClient.Connection.start_link()

    assert_receive {:channel_joined, _}, 5_000
    Process.sleep(500)

    assert Process.alive?(Process.whereis(PyreClient.Connection))
  end
end
