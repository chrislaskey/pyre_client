defmodule PyreClient.ToolsTest do
  use ExUnit.Case, async: true

  alias PyreClient.Tools

  @test_dir System.tmp_dir!()
            |> Path.join("pyre_client_tools_test_#{System.unique_integer([:positive])}")

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

  test "resolve_path! allows absolute paths within allowed directories" do
    abs_path = Path.join(@test_dir, "test.txt")
    result = Tools.resolve_path!(abs_path, @test_dir, [@test_dir])
    assert result == abs_path
  end

  test "default_allowed_commands returns a list" do
    commands = Tools.default_allowed_commands()
    assert is_list(commands)
    assert "git" in commands
    assert "mix" in commands
  end
end
