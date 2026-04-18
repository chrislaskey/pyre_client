# Stage 7 — Testing Strategy

## Overview

Testing covers the full execution layer: WebSocket client, LLM backends, tool system, agentic loop, and session management. We use a layered approach:

1. **Unit tests** — Protocol encoding/decoding, Channel state machine, LLM Config, Session
2. **Tool tests** — Tool definitions, path validation, command sandboxing
3. **Executor tests** — Command execution and LLM routing
4. **LLM backend tests** — Mock backend, ClaudeCLI (with overridden executable)
5. **Integration tests** — Connection against a real (minimal) Phoenix endpoint

## Layer 1: Unit Tests (No Network)

### Protocol Tests

Pure input/output — the easiest to test.

```elixir
# test/pyre_client/protocol_test.exs
defmodule PyreClient.ProtocolTest do
  use ExUnit.Case, async: true

  alias PyreClient.Protocol
  alias PyreClient.Protocol.Message

  test "encode/decode round-trip" do
    msg = Protocol.join("pyre:connections", "1", %{"status" => "active"})
    assert {:ok, json} = Protocol.encode(msg)
    assert {:ok, decoded} = Protocol.decode(json)
    assert decoded.topic == "pyre:connections"
    assert decoded.event == "phx_join"
    assert decoded.payload["status"] == "active"
  end

  test "decode V2 array format" do
    raw = ~s(["1","2","pyre:connections","action",{"type":"execute_prompt"}])
    assert {:ok, msg} = Protocol.decode(raw)
    assert msg.join_ref == "1"
    assert msg.ref == "2"
    assert msg.event == "action"
  end

  test "decode rejects invalid format" do
    assert {:error, {:invalid_message_format, _}} = Protocol.decode(~s({"not":"an_array"}))
  end

  test "heartbeat message" do
    msg = Protocol.heartbeat("42")
    assert msg.topic == "phoenix"
    assert msg.event == "heartbeat"
    assert msg.ref == "42"
  end

  test "reply helpers" do
    ok = %Message{event: "phx_reply", ref: "1", payload: %{"status" => "ok", "response" => %{}}}
    err = %Message{event: "phx_reply", ref: "1", payload: %{"status" => "error", "response" => %{"reason" => "bad"}}}

    assert Protocol.ok_reply?(ok)
    refute Protocol.ok_reply?(err)
    assert Protocol.reply_to?(ok, "1")
    refute Protocol.reply_to?(ok, "2")
  end
end
```

### Channel State Machine Tests

```elixir
# test/pyre_client/channel_test.exs
defmodule PyreClient.ChannelTest do
  use ExUnit.Case, async: true

  alias PyreClient.Channel
  alias PyreClient.Protocol.Message

  setup do
    ch = Channel.new("test-conn-1")
    {:ok, ch: ch}
  end

  test "starts disconnected", %{ch: ch} do
    assert ch.status == :disconnected
  end

  test "on_connected sends join and transitions to :joining", %{ch: ch} do
    {frames, ch} = Channel.on_connected(ch)
    assert ch.status == :joining
    assert length(frames) == 1

    [{:text, json}] = frames
    assert {:ok, msg} = PyreClient.Protocol.decode(json)
    assert msg.event == "phx_join"
    assert msg.topic == "pyre:connections"
    assert msg.payload["connection_id"] == "test-conn-1"
  end

  test "successful join reply transitions to :joined", %{ch: ch} do
    {_frames, ch} = Channel.on_connected(ch)
    join_ref = ch.join_ref

    reply = %Message{
      join_ref: join_ref, ref: join_ref, topic: "pyre:connections",
      event: "phx_reply", payload: %{"status" => "ok", "response" => %{}}
    }

    {frames, ch} = Channel.handle_message(reply, ch)
    assert ch.status == :joined
    assert frames == []
  end

  test "failed join reply transitions to :disconnected", %{ch: ch} do
    {_frames, ch} = Channel.on_connected(ch)
    join_ref = ch.join_ref

    reply = %Message{
      join_ref: join_ref, ref: join_ref, topic: "pyre:connections",
      event: "phx_reply", payload: %{"status" => "error", "response" => %{"reason" => "unauthorized"}}
    }

    {_frames, ch} = Channel.handle_message(reply, ch)
    assert ch.status == :disconnected
  end

  test "send_update_metadata when joined produces a frame", %{ch: ch} do
    ch = join_channel(ch)
    {frames, _ch} = Channel.send_update_metadata(ch, %{"available_capacity" => 0})
    assert length(frames) == 1
  end

  test "send_update_metadata when not joined returns no frames", %{ch: ch} do
    {frames, _ch} = Channel.send_update_metadata(ch, %{"available_capacity" => 0})
    assert frames == []
  end

  test "on_disconnected resets state", %{ch: ch} do
    ch = join_channel(ch)
    ch = Channel.on_disconnected(ch)
    assert ch.status == :disconnected
    assert ch.join_ref == nil
  end

  defp join_channel(ch) do
    {_frames, ch} = Channel.on_connected(ch)
    join_ref = ch.join_ref
    reply = %Message{
      join_ref: join_ref, ref: join_ref, topic: "pyre:connections",
      event: "phx_reply", payload: %{"status" => "ok", "response" => %{}}
    }
    {_frames, ch} = Channel.handle_message(reply, ch)
    ch
  end
end
```

### Session Tests

```elixir
# test/pyre_client/session_test.exs
defmodule PyreClient.SessionTest do
  use ExUnit.Case, async: true

  alias PyreClient.Session

  test "generate_id returns a valid UUID v4 string" do
    id = Session.generate_id()
    assert String.match?(id, ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/)
  end

  test "generate_id returns unique values" do
    ids = for _ <- 1..100, do: Session.generate_id()
    assert length(Enum.uniq(ids)) == 100
  end

  test "generate_for_stages returns a map of stage => UUID" do
    stages = [:architecting, :engineering, :shipping]
    result = Session.generate_for_stages(stages)

    assert map_size(result) == 3
    assert Map.has_key?(result, :architecting)
    assert Map.has_key?(result, :engineering)
    assert Map.has_key?(result, :shipping)
    assert Enum.all?(Map.values(result), &String.match?(&1, ~r/^[0-9a-f]{8}-/))
  end
end
```

### Session Registry Tests

```elixir
# test/pyre_client/session/registry_test.exs
defmodule PyreClient.Session.RegistryTest do
  use ExUnit.Case, async: false

  alias PyreClient.Session.Registry

  setup do
    start_supervised!(Registry)
    :ok
  end

  test "get returns nil for unknown session" do
    assert Registry.get("unknown-id") == nil
  end

  test "put and get round-trip" do
    Registry.put("pyre-uuid-1", "cursor-session-abc")
    assert Registry.get("pyre-uuid-1") == "cursor-session-abc"
  end

  test "put overwrites existing mapping" do
    Registry.put("pyre-uuid-1", "old-value")
    Registry.put("pyre-uuid-1", "new-value")
    assert Registry.get("pyre-uuid-1") == "new-value"
  end
end
```

## Layer 2: Tool Tests

### Tool Definition Tests

```elixir
# test/pyre_client/tools_test.exs
defmodule PyreClient.ToolsTest do
  use ExUnit.Case, async: true

  alias PyreClient.Tools

  @test_dir System.tmp_dir!() |> Path.join("pyre_client_tools_test")

  setup do
    File.mkdir_p!(@test_dir)
    File.write!(Path.join(@test_dir, "test.txt"), "hello world")

    on_exit(fn -> File.rm_rf!(@test_dir) end)

    :ok
  end

  test "for_role returns tools for programmer (all tools)" do
    tools = Tools.for_role(:programmer, @test_dir, allowed_paths: [@test_dir])
    names = Enum.map(tools, & &1.name)

    assert "read_file" in names
    assert "write_file" in names
    assert "list_directory" in names
    assert "run_command" in names
  end

  test "for_role returns tools for qa_reviewer (read-only)" do
    tools = Tools.for_role(:qa_reviewer, @test_dir, allowed_paths: [@test_dir])
    names = Enum.map(tools, & &1.name)

    assert "read_file" in names
    refute "write_file" in names
    assert "list_directory" in names
    assert "run_command" in names
  end

  test "for_role raises without allowed_paths" do
    assert_raise ArgumentError, ~r/No allowed paths/, fn ->
      Tools.for_role(:programmer, @test_dir)
    end
  end

  test "resolve_path! blocks path traversal" do
    assert_raise ArgumentError, ~r/Path traversal blocked/, fn ->
      Tools.resolve_path!("../../etc/passwd", @test_dir, [@test_dir])
    end
  end

  test "resolve_path! allows paths within allowed directories" do
    path = Tools.resolve_path!("test.txt", @test_dir, [@test_dir])
    assert path == Path.join(@test_dir, "test.txt")
  end
end
```

## Layer 3: Executor Tests

The Executor is a GenServer that spawns execution processes. Testing the full dispatch flow requires the Connection process (for `send_to_server`), so executor tests are deferred to the integration layer. The LLM routing logic is exercised indirectly through the LLM backend tests and AgenticLoop tests.

## Layer 4: LLM Backend Tests

### Mock Backend Tests

```elixir
# test/pyre_client/llm/mock_test.exs
defmodule PyreClient.LLM.MockTest do
  use ExUnit.Case, async: false

  alias PyreClient.LLM.Mock

  test "generate/3 returns mock response from process dictionary" do
    Process.put(:mock_llm_responses, [{:ok, "hello world"}])
    assert {:ok, "hello world"} = Mock.generate("standard", [%{role: :user, content: "hi"}], [])
  end

  test "generate/3 consumes responses in order" do
    Process.put(:mock_llm_responses, [
      {:ok, "first"},
      {:ok, "second"}
    ])

    assert {:ok, "first"} = Mock.generate("standard", [%{role: :user, content: "1"}], [])
    assert {:ok, "second"} = Mock.generate("standard", [%{role: :user, content: "2"}], [])
  end

  test "generate/3 returns error when no responses queued" do
    Process.delete(:mock_llm_responses)
    assert {:error, _} = Mock.generate("standard", [%{role: :user, content: "hi"}], [])
  end

  test "stream/3 delegates to generate (no streaming in mock)" do
    Process.put(:mock_llm_responses, [{:ok, "streamed"}])
    assert {:ok, "streamed"} = Mock.stream("standard", [%{role: :user, content: "hi"}], [])
  end

  test "chat/4 delegates to generate (no tools in mock)" do
    Process.put(:mock_llm_responses, [{:ok, "chatted"}])
    assert {:ok, "chatted"} = Mock.chat("standard", [%{role: :user, content: "hi"}], [], [])
  end
end
```

### ClaudeCLI Tests

```elixir
# test/pyre_client/llm/claude_cli_test.exs
defmodule PyreClient.LLM.ClaudeCLITest do
  use ExUnit.Case, async: false

  alias PyreClient.LLM.ClaudeCLI

  setup do
    original = Application.get_env(:pyre_client, :claude_cli_executable)
    Application.put_env(:pyre_client, :claude_cli_executable, "echo")

    on_exit(fn ->
      if original do
        Application.put_env(:pyre_client, :claude_cli_executable, original)
      else
        Application.delete_env(:pyre_client, :claude_cli_executable)
      end
    end)

    :ok
  end

  test "manages_tool_loop? returns true" do
    assert ClaudeCLI.manages_tool_loop?() == true
  end

  test "executable reads from application config" do
    Application.put_env(:pyre_client, :claude_cli_executable, "/usr/local/bin/my-claude")
    # Verify through the module's config reading (implementation detail)
  end

  test "map_model maps standard model names" do
    assert ClaudeCLI.map_model("anthropic:claude-sonnet-4-20250514") == "sonnet"
    assert ClaudeCLI.map_model("anthropic:claude-opus-4-20250514") == "opus"
    assert ClaudeCLI.map_model("anthropic:claude-haiku-4-5") == "haiku"
    assert ClaudeCLI.map_model("sonnet") == "sonnet"
    assert ClaudeCLI.map_model("custom-model") == "custom-model"
  end

  test "extract_prompts separates system and user messages" do
    messages = [
      %{role: :system, content: "You are a helper"},
      %{role: :user, content: "Do something"}
    ]

    {system, user} = ClaudeCLI.extract_prompts(messages)
    assert system == "You are a helper"
    assert String.contains?(user, "Do something")
    assert String.contains?(user, "<persona>")
  end
end
```

### LLM Config Tests

```elixir
# test/pyre_client/llm/config_test.exs
defmodule PyreClient.LLM.ConfigTest do
  use ExUnit.Case, async: false

  alias PyreClient.LLM.Config

  test "included_backends returns all built-in backends" do
    backends = Config.included_backends()
    names = Enum.map(backends, & &1.name)

    assert "req_llm" in names
    assert "claude_cli" in names
    assert "cursor_cli" in names
    assert "codex_cli" in names
  end

  test "default_backend returns configured backend" do
    Application.put_env(:pyre_client, :llm_backend, :claude_cli)
    assert Config.default_backend() == PyreClient.LLM.ClaudeCLI
    Application.delete_env(:pyre_client, :llm_backend)
  end

  test "default_backend falls back to ReqLLM when not configured" do
    Application.delete_env(:pyre_client, :llm_backend)
    assert Config.default_backend() == PyreClient.LLM.ReqLLM
  end
end
```

## Layer 5: Integration Tests

### Mock WebSocket Server

```elixir
# test/support/mock_server.ex
defmodule PyreClient.Test.MockServer do
  @moduledoc """
  A minimal Phoenix endpoint for testing PyreClient.Connection.
  Runs on a random port, speaks the pyre:* channel protocol.
  """

  defmodule Endpoint do
    use Phoenix.Endpoint, otp_app: :pyre_client
    socket "/pyre", PyreClient.Test.MockServer.Socket,
      websocket: [connect_info: [:peer_data]]
  end

  defmodule Socket do
    use Phoenix.Socket
    channel "pyre:*", PyreClient.Test.MockServer.Channel

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
      if pid = Process.get(:test_pid), do: send(pid, {:channel_joined, params})
      {:ok, %{message: "connected"}, socket}
    end

    def handle_in("action_output", payload, socket) do
      if pid = Process.get(:test_pid), do: send(pid, {:action_output, payload})
      {:noreply, socket}
    end

    def handle_in("action_complete", payload, socket) do
      if pid = Process.get(:test_pid), do: send(pid, {:action_complete, payload})
      {:noreply, socket}
    end

    def handle_in("update_metadata", payload, socket) do
      if pid = Process.get(:test_pid), do: send(pid, {:update_metadata, payload})
      {:reply, :ok, socket}
    end

    def handle_info(:after_join, socket), do: {:noreply, socket}
  end

  def start(test_pid) do
    port = Enum.random(50_000..59_999)
    Application.put_env(:pyre_client, Endpoint,
      http: [port: port], server: true, pubsub_server: PyreClient.Test.PubSub)
    start_supervised!({Phoenix.PubSub, name: PyreClient.Test.PubSub})
    start_supervised!(Endpoint)
    Process.put(:test_pid, test_pid)
    %{port: port, url: "ws://localhost:#{port}/pyre/websocket"}
  end
end
```

### Connection Integration Test

```elixir
# test/pyre_client/connection_test.exs
defmodule PyreClient.ConnectionTest do
  use ExUnit.Case, async: false

  alias PyreClient.Test.MockServer

  setup do
    %{url: url} = MockServer.start(self())
    Application.put_env(:pyre_client, :server_url, url)
    Application.put_env(:pyre_client, :connection_id, "test-#{System.unique_integer()}")

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
```

## Test Matrix

| Module | Test Type | Async? | Dependencies |
|--------|-----------|--------|-------------|
| `Protocol` | Unit | Yes | None (pure) |
| `Channel` | Unit | Yes | Protocol only |
| `Session` | Unit | Yes | None (`:crypto`) |
| `Session.Registry` | Unit | No | Agent process |
| `Tools` | Unit | Yes | `req_llm` (for `ReqLLM.Tool`) |
| `Executor` | Integration | No | MockServer (via Connection) |
| `PyreClient.LLM.Mock` | Unit | No | Process dictionary |
| `PyreClient.LLM.ClaudeCLI` | Unit | No | Application env |
| `PyreClient.LLM.Config` | Unit | No | Application env |
| `Connection` | Integration | No | MockServer (Phoenix) |

## What We Don't Test (Initially)

- **AgenticLoop integration** — Requires a real LLM or a mock that returns proper `ReqLLM.Response` structs with tool calls. Can be added later with carefully crafted mock sequences.
- **Reconnection under network failure** — Hard to simulate reliably. Trust WebSockex's reconnection + our `handle_disconnect` logic.
- **Full end-to-end with pyre_app** — Requires the full stack. Smoke test or manual verification.
- **CursorCLI warm-up session** — Requires the cursor-agent binary. Tested manually.
- **ReqLLM integration** — Requires API keys. Tested manually or via CI with secrets.

## Running Tests

```bash
cd pyre_client
mix test                                     # All tests
mix test test/pyre_client/protocol_test.exs  # Just protocol
mix test test/pyre_client/tools_test.exs     # Just tools
mix test test/pyre_client/llm/               # Just LLM backend tests
mix test --only integration                  # Just integration tests (tagged)
```
