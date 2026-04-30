defmodule PyreClient.Runner do
  @moduledoc """
  Receives action dispatches, routes to action modules, manages capacity.

  Routes actions through `PyreClient.Actions.resolve/1` to the appropriate
  implementation module. Handles the interactive loop (action_continue /
  action_finish) as shared infrastructure for all action types.

  Has no knowledge of workflows, stages, or orchestration.
  """

  use GenServer

  require Logger

  @name __MODULE__

  defstruct [
    :max_capacity,
    # %{execution_id => pid} — all spawned processes (routing + cleanup)
    :active_executions,
    # %{reservation_id => pid} — reserves only, the capacity gate
    :workflow_slots
  ]

  # 24 hours — matches workflow-level timeout
  @execution_timeout 86_400_000

  @resumed_conversation_note """
  NOTE: This is a resumed conversation, but we don't have a reference session \
  ID. Do your best to pick up context based on local or remote changes. Then \
  reply back to the user telling them you don't have access to the previous \
  discussion, but here is what you do know based on the prompt and existing \
  code (which can also be nothing — "I don't have enough to go on yet" — or \
  if you do have some: "here is my understanding..."), and then ask some \
  clarifying questions for the user so in the next response you can start \
  doing work.\
  """

  # --- Start ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  @impl true
  def init(_opts) do
    state = %__MODULE__{
      max_capacity: PyreClient.Config.max_capacity(),
      active_executions: %{},
      workflow_slots: %{}
    }

    {:ok, state}
  end

  # --- Public API ---

  @doc "Handle an action dispatch from the server."
  def handle_action(payload) do
    GenServer.cast(@name, {:handle_action, payload})
  end

  @doc "Called when the WebSocket disconnects."
  def on_disconnected do
    GenServer.cast(@name, :on_disconnected)
  end

  @doc "Forward an action_continue from the server to a blocked execution process."
  def handle_continue(payload) do
    GenServer.cast(@name, {:handle_continue, payload})
  end

  @doc "Forward an action_finish from the server to release an execution."
  def handle_finish(payload) do
    GenServer.cast(@name, {:handle_finish, payload})
  end

  # --- Callbacks ---

  @impl true
  def handle_cast({:handle_action, payload}, state) do
    execution_id = payload["execution_id"]
    action_type = payload["action"]

    cond do
      action_type == "reserve" and not has_workflow_capacity?(state) ->
        Logger.info("[PyreClient.Runner] No workflow slots, rejecting reserve #{execution_id}")

        send_to_server("action_output", %{
          "execution_id" => execution_id,
          "type" => "ack",
          "status" => "rejected"
        })

        {:noreply, state}

      action_type == "reserve" ->
        pid = spawn_execution(execution_id, action_type, payload)
        active = Map.put(state.active_executions, execution_id, pid)
        slots = Map.put(state.workflow_slots, execution_id, pid)
        state = %{state | active_executions: active, workflow_slots: slots}
        update_server_capacity(state)
        {:noreply, state}

      not under_safety_cap?(state) ->
        Logger.info("[PyreClient.Runner] Safety cap reached, cannot execute #{execution_id}")
        {:noreply, state}

      true ->
        pid = spawn_execution(execution_id, action_type, payload)
        active = Map.put(state.active_executions, execution_id, pid)
        state = %{state | active_executions: active}
        {:noreply, state}
    end
  end

  def handle_cast(:on_disconnected, state) do
    Logger.warning(
      "[PyreClient.Runner] Disconnected, #{map_size(state.active_executions)} executions still running"
    )

    {:noreply, state}
  end

  def handle_cast({:handle_continue, payload}, state) do
    execution_id = payload["execution_id"]

    case Map.get(state.active_executions, execution_id) do
      nil ->
        Logger.info(
          "[PyreClient.Runner] action_continue for unknown execution #{execution_id}, " <>
            "starting recovery session"
        )

        pid = spawn_recovery_session(execution_id, payload)
        active = Map.put(state.active_executions, execution_id, pid)
        {:noreply, %{state | active_executions: active}}

      pid ->
        send(pid, {:continue, payload})
        {:noreply, state}
    end
  end

  def handle_cast({:handle_finish, payload}, state) do
    execution_id = payload["execution_id"]

    case Map.get(state.active_executions, execution_id) do
      nil ->
        Logger.info(
          "[PyreClient.Runner] action_finish for unknown execution #{execution_id}, acking"
        )

        send_to_server("action_complete", %{
          "execution_id" => execution_id,
          "status" => "ok",
          "result" => %{}
        })

        {:noreply, state}

      pid ->
        send(pid, :finish)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:execution_done, execution_id}, state) do
    active = Map.delete(state.active_executions, execution_id)
    had_slot = Map.has_key?(state.workflow_slots, execution_id)
    slots = Map.delete(state.workflow_slots, execution_id)
    state = %{state | active_executions: active, workflow_slots: slots}
    if had_slot, do: update_server_capacity(state)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    removed_ids =
      state.active_executions
      |> Enum.filter(fn {_id, p} -> p == pid end)
      |> Enum.map(fn {id, _p} -> id end)

    if removed_ids != [] do
      active =
        state.active_executions
        |> Enum.reject(fn {_id, p} -> p == pid end)
        |> Map.new()

      slots_changed = Enum.any?(removed_ids, &Map.has_key?(state.workflow_slots, &1))

      slots =
        Enum.reduce(removed_ids, state.workflow_slots, fn id, acc -> Map.delete(acc, id) end)

      state = %{state | active_executions: active, workflow_slots: slots}
      if slots_changed, do: update_server_capacity(state)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Execution Dispatch ---

  defp spawn_execution(execution_id, action_type, payload) do
    runner_pid = self()

    {pid, _ref} =
      spawn_monitor(fn ->
        execute(execution_id, action_type, payload)
        send(runner_pid, {:execution_done, execution_id})
      end)

    pid
  end

  defp execute(execution_id, "reserve", _payload) do
    execute_reserve(execution_id)
  end

  defp execute(execution_id, "test_connection", _payload) do
    execute_test_connection(execution_id)
  end

  defp execute(execution_id, action_type, payload) do
    case PyreClient.Actions.resolve(action_type) do
      {:ok, action_module} ->
        context = build_context(execution_id, payload)

        # Phase 1: LLM call (+ interactive loop if interactive)
        llm_result =
          if context.interactive? do
            start_interactive_session(execution_id, context)
          else
            PyreClient.Actions.LLM.call(context)
          end

        # Phase 2: Action module processes the LLM result
        case llm_result do
          {:ok, _text} ->
            # Put the LLM result text into context for the action module.
            # Actions.LLM.call/1 checks for :llm_result_text and returns it
            # directly, so action modules don't double-call the LLM.
            context = Map.put(context, :llm_result_text, elem(llm_result, 1))

            case action_module.execute(payload, context) do
              {:ok, result} ->
                send_to_server("action_complete", %{
                  "execution_id" => execution_id,
                  "status" => "ok",
                  "result" => result
                })

              {:error, reason} ->
                Logger.error(
                  "[PyreClient.Runner] #{execution_id}: action error: #{inspect(reason)}"
                )

                send_to_server("action_complete", %{
                  "execution_id" => execution_id,
                  "status" => "error",
                  "result" => %{"error" => inspect(reason)}
                })
            end

          {:error, reason} ->
            Logger.error("[PyreClient.Runner] #{execution_id}: LLM error: #{inspect(reason)}")

            send_to_server("action_complete", %{
              "execution_id" => execution_id,
              "status" => "error",
              "result" => %{"error" => inspect(reason)}
            })
        end

      :error ->
        Logger.warning("[PyreClient.Runner] #{execution_id}: unknown action type: #{action_type}")

        send_to_server("action_complete", %{
          "execution_id" => execution_id,
          "status" => "error",
          "result" => %{"error" => "Unknown action type: #{action_type}"}
        })
    end
  end

  # --- Reserve (capacity hold) ---

  defp execute_reserve(execution_id) do
    Logger.info("[PyreClient.Runner] #{execution_id}: reserve — acking and holding capacity")

    send_to_server("action_output", %{
      "execution_id" => execution_id,
      "type" => "ack",
      "status" => "accepted"
    })

    # Block until the server sends action_finish when the workflow completes.
    # This keeps the execution in active_executions, holding the capacity slot.
    receive do
      :finish ->
        Logger.info("[PyreClient.Runner] #{execution_id}: reserve — released")
    after
      @execution_timeout ->
        Logger.error("[PyreClient.Runner] #{execution_id}: reserve — timed out")
    end
  end

  # --- Test Connection ---

  defp execute_test_connection(execution_id) do
    Logger.info("[PyreClient.Runner] #{execution_id}: test_connection — responding")

    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    send_to_server("action_complete", %{
      "execution_id" => execution_id,
      "status" => "ok",
      "result" => %{
        "message" => "Received test connection request! Responded at #{timestamp}"
      }
    })
  end

  # --- Interactive Session ---

  # Shared entry point for interactive sessions. Makes the initial LLM call,
  # sends the result back to the server, and enters the interactive loop.
  # Used by both normal action dispatch and recovery from unknown continues.
  defp start_interactive_session(execution_id, context) do
    case PyreClient.Actions.LLM.call(context) do
      {:ok, text} ->
        send_to_server("action_result", %{
          "execution_id" => execution_id,
          "result_text" => text
        })

        interactive_loop(execution_id, context, text)

      {:error, _} = error ->
        error
    end
  end

  defp interactive_loop(execution_id, context, last_text) do
    receive do
      {:continue, payload} ->
        user_message = payload["message"] || ""
        session_id = Keyword.get(context.opts, :session_id)

        Logger.info(
          "[PyreClient.Runner] #{execution_id}: interactive continue (session: #{session_id})"
        )

        messages = [%{role: :user, content: user_message}]
        resume_opts = Keyword.put(context.opts, :resume, session_id)
        resume_opts = Keyword.put(resume_opts, :output_fn, context.output_fn)
        resume_opts = Keyword.put(resume_opts, :messages, messages)
        resume_context = %{context | opts: resume_opts}

        case PyreClient.Actions.LLM.call(resume_context) do
          {:ok, text} ->
            send_to_server("action_result", %{
              "execution_id" => execution_id,
              "result_text" => text
            })

            interactive_loop(execution_id, context, text)

          {:error, reason} ->
            Logger.error(
              "[PyreClient.Runner] #{execution_id}: interactive LLM error: #{inspect(reason)}"
            )

            {:error, reason}
        end

      :finish ->
        Logger.info("[PyreClient.Runner] #{execution_id}: interactive finished")
        {:ok, last_text}
    after
      @execution_timeout ->
        Logger.error("[PyreClient.Runner] #{execution_id}: interactive loop timed out")
        {:error, :interactive_timeout}
    end
  end

  # --- Recovery Session ---

  # Spawns a new interactive session when action_continue arrives for an
  # execution_id we don't recognize (e.g., after a client restart). Creates
  # a fresh session ID and runs the initial LLM call with the user's message
  # plus a note explaining the session context was lost.
  defp spawn_recovery_session(execution_id, payload) do
    runner_pid = self()

    {pid, _ref} =
      spawn_monitor(fn ->
        execute_recovery_session(execution_id, payload)
        send(runner_pid, {:execution_done, execution_id})
      end)

    pid
  end

  defp execute_recovery_session(execution_id, payload) do
    user_message = payload["message"] || ""
    working_dir = payload["working_dir"]
    new_session_id = PyreClient.Session.generate_id()

    backend = PyreClient.Config.default_backend()
    model = PyreClient.Config.resolve_model("standard", backend)

    prompt = @resumed_conversation_note <> "\n\nUser message:\n" <> user_message

    messages = [%{role: :user, content: prompt}]

    tools = build_tools("generalist", working_dir, [working_dir || "."], nil)

    opts = [
      messages: messages,
      session_id: new_session_id,
      streaming: true,
      working_dir: working_dir
    ]

    output_fn = fn token -> send_output(execution_id, token) end

    context = %{
      execution_id: execution_id,
      backend: backend,
      model: model,
      tools: tools,
      opts: opts,
      output_fn: output_fn,
      send_to_server: &send_to_server/2,
      interactive?: true
    }

    Logger.info(
      "[PyreClient.Runner] #{execution_id}: recovery session started " <>
        "(session: #{new_session_id}, working_dir: #{inspect(working_dir)})"
    )

    case start_interactive_session(execution_id, context) do
      {:ok, _text} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "[PyreClient.Runner] #{execution_id}: recovery session error: #{inspect(reason)}"
        )

        send_to_server("action_complete", %{
          "execution_id" => execution_id,
          "status" => "error",
          "result" => %{"error" => inspect(reason)}
        })
    end
  end

  # --- Context Building ---

  defp build_context(execution_id, payload) do
    inner = payload["payload"] || %{}
    model_tier = inner["model_tier"] || "standard"
    role = inner["role"]
    working_dir = inner["working_dir"]
    allowed_paths = inner["allowed_paths"] || []
    allowed_commands = inner["allowed_commands"]
    opts_map = inner["opts"] || %{}

    # Messages arrive pre-built from the server, including the full persona
    # system prompt and user message with artifacts/context. The client
    # passes them directly to the LLM backend — no persona loading needed.
    messages = inner["messages"] || []

    # The server sets interactive: true|false authoritatively. This determines
    # whether the client sends action_result (stays alive) or action_complete
    # (frees capacity) after the initial LLM call.
    interactive? = inner["interactive"] == true

    # Session IDs are generated by the server (Pyre.Session.generate_for_stages/1)
    # and included in the payload. The client stores the mapping for CLI session
    # resumption during action_continue.
    session_id = get_in(opts_map, ["session_id"])

    backend = PyreClient.Config.default_backend()
    model = PyreClient.Config.resolve_model(model_tier, backend)

    messages =
      Enum.map(messages, fn msg ->
        %{role: String.to_existing_atom(msg["role"]), content: msg["content"]}
      end)

    tools = build_tools(role, working_dir, allowed_paths, allowed_commands)

    opts =
      opts_map
      |> Enum.map(fn {k, v} -> {String.to_existing_atom(k), v} end)
      |> Keyword.new()
      |> Keyword.put(:messages, messages)

    opts = if session_id, do: Keyword.put(opts, :session_id, session_id), else: opts

    output_fn = fn token -> send_output(execution_id, token) end

    %{
      execution_id: execution_id,
      backend: backend,
      model: model,
      tools: tools,
      opts: opts,
      output_fn: output_fn,
      send_to_server: &send_to_server/2,
      interactive?: interactive?
    }
  end

  # --- Tool Building ---

  defp build_tools(nil, _working_dir, _allowed_paths, _allowed_commands), do: []
  defp build_tools(_role, nil, _allowed_paths, _allowed_commands), do: []

  defp build_tools(role, working_dir, allowed_paths, allowed_commands) do
    role_atom = String.to_existing_atom(role)
    tool_opts = [allowed_paths: allowed_paths]

    tool_opts =
      if allowed_commands,
        do: Keyword.put(tool_opts, :allowed_commands, allowed_commands),
        else: tool_opts

    PyreClient.Tools.for_role(role_atom, working_dir, tool_opts)
  rescue
    ArgumentError -> []
  end

  # --- Output Streaming ---

  defp send_output(execution_id, content) do
    send_to_server("action_output", %{
      "execution_id" => execution_id,
      "content" => content
    })
  end

  # --- Helpers ---

  defp has_workflow_capacity?(state) do
    map_size(state.workflow_slots) < state.max_capacity
  end

  defp under_safety_cap?(state) do
    map_size(state.active_executions) < max(state.max_capacity * 3, 1)
  end

  defp current_available_capacity(state) do
    state.max_capacity - map_size(state.workflow_slots)
  end

  defp send_to_server(event, payload) do
    WebSockex.cast(PyreClient.Connection, {:send_event, event, payload})
  end

  defp update_server_capacity(state) do
    PyreClient.Connection.update_metadata(%{
      "max_capacity" => state.max_capacity,
      "available_capacity" => current_available_capacity(state)
    })
  end
end
