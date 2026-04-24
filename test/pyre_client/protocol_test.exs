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
    raw = ~s(["1","2","pyre:connections","action",{"action":"prompt"}])
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
    ok = %Message{
      event: "phx_reply",
      ref: "1",
      payload: %{"status" => "ok", "response" => %{}}
    }

    err = %Message{
      event: "phx_reply",
      ref: "1",
      payload: %{"status" => "error", "response" => %{"reason" => "bad"}}
    }

    assert Protocol.ok_reply?(ok)
    refute Protocol.ok_reply?(err)
    assert Protocol.reply_to?(ok, "1")
    refute Protocol.reply_to?(ok, "2")
  end

  test "next_ref increments monotonically" do
    Process.delete(:phoenix_ref_counter)
    ref1 = Protocol.next_ref()
    ref2 = Protocol.next_ref()
    assert String.to_integer(ref2) > String.to_integer(ref1)
  end

  test "join message has matching join_ref and ref" do
    msg = Protocol.join("pyre:connections", "5", %{})
    assert msg.join_ref == "5"
    assert msg.ref == "5"
  end

  test "push message includes all fields" do
    msg = Protocol.push("pyre:connections", "1", "2", "update_metadata", %{"key" => "val"})
    assert msg.join_ref == "1"
    assert msg.ref == "2"
    assert msg.topic == "pyre:connections"
    assert msg.event == "update_metadata"
    assert msg.payload["key"] == "val"
  end

  test "leave message" do
    msg = Protocol.leave("pyre:connections", "1", "3")
    assert msg.event == "phx_leave"
    assert msg.join_ref == "1"
    assert msg.ref == "3"
  end
end
