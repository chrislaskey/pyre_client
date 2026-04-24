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
