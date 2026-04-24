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
      join_ref: join_ref,
      ref: join_ref,
      topic: "pyre:connections",
      event: "phx_reply",
      payload: %{"status" => "ok", "response" => %{}}
    }

    {frames, ch} = Channel.handle_message(reply, ch)
    assert ch.status == :joined
    assert frames == []
  end

  test "failed join reply transitions to :disconnected", %{ch: ch} do
    {_frames, ch} = Channel.on_connected(ch)
    join_ref = ch.join_ref

    reply = %Message{
      join_ref: join_ref,
      ref: join_ref,
      topic: "pyre:connections",
      event: "phx_reply",
      payload: %{"status" => "error", "response" => %{"reason" => "unauthorized"}}
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

  test "action dispatch delegates to Runner (no crash)", %{ch: ch} do
    ch = join_channel(ch)

    action_msg = %Message{
      topic: "pyre:connections",
      event: "action",
      payload: %{"action" => "prompt", "execution_id" => "exec-1"}
    }

    {frames, ch} = Channel.handle_message(action_msg, ch)
    assert frames == []
    assert ch.status == :joined
  end

  test "presence_diff is handled silently", %{ch: ch} do
    ch = join_channel(ch)

    msg = %Message{
      topic: "pyre:connections",
      event: "presence_diff",
      payload: %{"joins" => %{"user1" => %{}}, "leaves" => %{}}
    }

    {frames, ch} = Channel.handle_message(msg, ch)
    assert frames == []
    assert ch.status == :joined
  end

  test "phx_close transitions to disconnected", %{ch: ch} do
    ch = join_channel(ch)

    msg = %Message{
      topic: "pyre:connections",
      event: "phx_close",
      payload: %{}
    }

    {_frames, ch} = Channel.handle_message(msg, ch)
    assert ch.status == :disconnected
  end

  test "phx_error transitions to disconnected", %{ch: ch} do
    ch = join_channel(ch)

    msg = %Message{
      topic: "pyre:connections",
      event: "phx_error",
      payload: %{}
    }

    {_frames, ch} = Channel.handle_message(msg, ch)
    assert ch.status == :disconnected
  end

  test "send_event when joined produces a frame", %{ch: ch} do
    ch = join_channel(ch)
    {frames, _ch} = Channel.send_event(ch, "action_complete", %{"execution_id" => "1"})
    assert length(frames) == 1
  end

  test "send_event when not joined returns no frames", %{ch: ch} do
    {frames, _ch} = Channel.send_event(ch, "action_complete", %{})
    assert frames == []
  end

  test "status returns channel info", %{ch: ch} do
    status = Channel.status(ch)
    assert status.status == :disconnected
    assert status.connection_id == "test-conn-1"
    assert status.topic == "pyre:connections"
  end

  defp join_channel(ch) do
    {_frames, ch} = Channel.on_connected(ch)
    join_ref = ch.join_ref

    reply = %Message{
      join_ref: join_ref,
      ref: join_ref,
      topic: "pyre:connections",
      event: "phx_reply",
      payload: %{"status" => "ok", "response" => %{}}
    }

    {_frames, ch} = Channel.handle_message(reply, ch)
    ch
  end
end
