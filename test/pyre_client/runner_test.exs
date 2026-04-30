defmodule PyreClient.RunnerTest do
  use ExUnit.Case, async: false

  require Logger

  setup do
    # Configure Mock LLM backend so spawned processes use it
    original_backend = Application.get_env(:pyre_client, :llm_backend)
    Application.put_env(:pyre_client, :llm_backend, PyreClient.LLM.Mock)

    # Start a fake Connection process that captures WebSockex casts.
    # WebSockex.cast/2 sends {:"$websockex_cast", msg} to the named process,
    # so any process registered as PyreClient.Connection will receive them.
    test_pid = self()
    fake_conn = spawn_link(fn -> fake_connection_loop(test_pid) end)
    Process.register(fake_conn, PyreClient.Connection)

    # Start Runner
    start_supervised!(PyreClient.Runner)

    on_exit(fn ->
      if original_backend do
        Application.put_env(:pyre_client, :llm_backend, original_backend)
      else
        Application.delete_env(:pyre_client, :llm_backend)
      end
    end)

    :ok
  end

  # --- handle_finish ---

  describe "handle_finish" do
    test "unknown execution sends action_complete ack" do
      payload = %{"execution_id" => "unknown-finish-1"}
      GenServer.cast(PyreClient.Runner, {:handle_finish, payload})

      assert_receive {:server_cast, {:send_event, "action_complete", ack}}, 1_000
      assert ack["execution_id"] == "unknown-finish-1"
      assert ack["status"] == "ok"
      assert ack["result"] == %{}
    end

    test "known execution sends :finish to process" do
      test_pid = self()

      exec_pid =
        spawn_link(fn ->
          receive do
            :finish -> send(test_pid, :got_finish)
          end
        end)

      :sys.replace_state(PyreClient.Runner, fn state ->
        %{state | active_executions: Map.put(state.active_executions, "known-finish-1", exec_pid)}
      end)

      payload = %{"execution_id" => "known-finish-1"}
      GenServer.cast(PyreClient.Runner, {:handle_finish, payload})

      assert_receive :got_finish, 1_000
    end
  end

  # --- handle_continue ---

  describe "handle_continue" do
    test "known execution forwards {:continue, payload} to process" do
      test_pid = self()

      exec_pid =
        spawn_link(fn ->
          receive do
            {:continue, payload} -> send(test_pid, {:got_continue, payload})
          end
        end)

      :sys.replace_state(PyreClient.Runner, fn state ->
        %{state | active_executions: Map.put(state.active_executions, "known-cont-1", exec_pid)}
      end)

      payload = %{"execution_id" => "known-cont-1", "message" => "keep going"}
      GenServer.cast(PyreClient.Runner, {:handle_continue, payload})

      assert_receive {:got_continue, ^payload}, 1_000
    end

    test "unknown execution spawns recovery session" do
      payload = %{"execution_id" => "unknown-cont-1", "message" => "please continue"}
      GenServer.cast(PyreClient.Runner, {:handle_continue, payload})

      # Recovery session should make an LLM call and send action_result
      assert_receive {:server_cast, {:send_event, "action_result", result}}, 5_000
      assert result["execution_id"] == "unknown-cont-1"
      assert is_binary(result["result_text"])

      # Verify execution is tracked in active_executions
      state = :sys.get_state(PyreClient.Runner)
      assert Map.has_key?(state.active_executions, "unknown-cont-1")

      cleanup_execution("unknown-cont-1")
    end

    test "recovery session enters interactive loop and handles finish" do
      payload = %{"execution_id" => "recovery-finish-1", "message" => "start work"}
      GenServer.cast(PyreClient.Runner, {:handle_continue, payload})

      # Wait for recovery session to start
      assert_receive {:server_cast, {:send_event, "action_result", _}}, 5_000

      # Send finish to end the interactive loop
      GenServer.cast(PyreClient.Runner, {:handle_finish, %{"execution_id" => "recovery-finish-1"}})

      # Wait for process to complete and be cleaned up from active_executions
      assert_eventually(fn ->
        state = :sys.get_state(PyreClient.Runner)
        not Map.has_key?(state.active_executions, "recovery-finish-1")
      end)
    end

    test "recovery session handles subsequent continue in interactive loop" do
      payload = %{"execution_id" => "recovery-cont-1", "message" => "start"}
      GenServer.cast(PyreClient.Runner, {:handle_continue, payload})

      # Wait for initial action_result from recovery
      assert_receive {:server_cast, {:send_event, "action_result", r1}}, 5_000
      assert r1["execution_id"] == "recovery-cont-1"

      # Send another continue through the interactive loop
      continue_payload = %{"execution_id" => "recovery-cont-1", "message" => "do more"}
      GenServer.cast(PyreClient.Runner, {:handle_continue, continue_payload})

      # Should get another action_result from the resumed LLM call
      assert_receive {:server_cast, {:send_event, "action_result", r2}}, 5_000
      assert r2["execution_id"] == "recovery-cont-1"

      cleanup_execution("recovery-cont-1")
    end
  end

  # --- Helpers ---

  defp fake_connection_loop(test_pid) do
    receive do
      {:"$websockex_cast", msg} ->
        send(test_pid, {:server_cast, msg})
        fake_connection_loop(test_pid)

      _other ->
        fake_connection_loop(test_pid)
    end
  end

  defp cleanup_execution(execution_id) do
    state = :sys.get_state(PyreClient.Runner)

    if pid = Map.get(state.active_executions, execution_id) do
      send(pid, :finish)
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        2_000 -> :ok
      end
    end
  end

  defp assert_eventually(fun, timeout \\ 2_000, interval \\ 50) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_assert_eventually(fun, deadline, interval)
  end

  defp do_assert_eventually(fun, deadline, interval) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) > deadline do
        flunk("Condition not met within timeout")
      else
        Process.sleep(interval)
        do_assert_eventually(fun, deadline, interval)
      end
    end
  end
end
