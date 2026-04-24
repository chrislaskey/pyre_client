defmodule PyreClient.Session do
  @moduledoc """
  Generates RFC 4122 v4 UUID session identifiers for CLI session persistence.

  Each stage in a workflow is pre-assigned a unique UUID at flow start time.
  These UUIDs are passed as `--session-id` on the initial call to a stage and
  as `--resume` for subsequent user-reply calls during interactive mode.
  """

  @doc """
  Generates a new RFC 4122 v4 UUID string.
  """
  @spec generate_id() :: String.t()
  def generate_id do
    <<a::32, b::16, _::4, c::12, _::2, d::14, e::48>> = :crypto.strong_rand_bytes(16)

    :io_lib.format(
      "~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b",
      [a, b, c, Bitwise.bor(d, 0x8000), e]
    )
    |> IO.iodata_to_binary()
  end

  @doc """
  Generates a UUID for each stage in the given list.

  Returns `%{phase_atom => uuid_string}`.
  """
  @spec generate_for_stages([atom()]) :: %{atom() => String.t()}
  def generate_for_stages(stages) do
    Map.new(stages, fn stage -> {stage, generate_id()} end)
  end
end
