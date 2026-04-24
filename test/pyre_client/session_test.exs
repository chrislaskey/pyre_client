defmodule PyreClient.SessionTest do
  use ExUnit.Case, async: true

  alias PyreClient.Session

  test "generate_id returns a valid UUID v4 string" do
    id = Session.generate_id()

    assert String.match?(
             id,
             ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
           )
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
