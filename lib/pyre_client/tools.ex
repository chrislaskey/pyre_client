default_allowed_commands = [
  "MIX_ENV=test mix",
  "mix",
  "elixir",
  "git",
  "cat",
  "ls",
  "grep",
  "find",
  "head",
  "tail",
  "wc",
  "mkdir",
  "echo"
]

defmodule PyreClient.Tools do
  @moduledoc """
  Tool definitions for LLM agent actions.

  Provides file system and shell tools that agents use to read, write,
  and execute commands. Tools are sandboxed to explicitly configured
  allowed paths via path validation.

  Default allowed commands: #{inspect(default_allowed_commands)}
  """

  @max_output_bytes 10_000

  @default_allowed_commands default_allowed_commands

  @doc "Returns the default allowed commands list."
  def default_allowed_commands, do: @default_allowed_commands

  @doc """
  Returns tools for a given agent role, scoped to the allowed paths.

  Raises `ArgumentError` if `:allowed_paths` is not provided or is empty.
  """
  def for_role(role, working_dir, opts \\ [])

  def for_role(:programmer, working_dir, opts), do: all_tools(working_dir, opts)
  def for_role(:test_writer, working_dir, opts), do: all_tools(working_dir, opts)
  def for_role(:software_engineer, working_dir, opts), do: all_tools(working_dir, opts)
  def for_role(:generalist, working_dir, opts), do: all_tools(working_dir, opts)
  def for_role(:prototype_engineer, working_dir, opts), do: all_tools(working_dir, opts)

  def for_role(:qa_reviewer, working_dir, opts), do: read_only_tools(working_dir, opts)
  def for_role(:designer, working_dir, opts), do: read_only_tools(working_dir, opts)
  def for_role(:product_manager, working_dir, opts), do: read_only_tools(working_dir, opts)
  def for_role(:shipper, working_dir, opts), do: read_only_tools(working_dir, opts)
  def for_role(:software_architect, working_dir, opts), do: read_only_tools(working_dir, opts)

  defp read_only_tools(working_dir, opts) do
    allowed = Keyword.get(opts, :allowed_commands, @default_allowed_commands)
    expanded_wd = Path.expand(working_dir)
    allowed_paths = build_allowed_paths!(expanded_wd, opts)

    [
      read_file_tool(expanded_wd, allowed_paths),
      list_directory_tool(expanded_wd, allowed_paths),
      run_command_tool(expanded_wd, allowed, allowed_paths)
    ]
  end

  defp all_tools(working_dir, opts) do
    allowed = Keyword.get(opts, :allowed_commands, @default_allowed_commands)
    expanded_wd = Path.expand(working_dir)
    allowed_paths = build_allowed_paths!(expanded_wd, opts)

    [
      read_file_tool(expanded_wd, allowed_paths),
      write_file_tool(expanded_wd, allowed_paths),
      list_directory_tool(expanded_wd, allowed_paths),
      run_command_tool(expanded_wd, allowed, allowed_paths)
    ]
  end

  defp build_allowed_paths!(expanded_wd, opts) do
    case Keyword.get(opts, :allowed_paths, []) do
      [] ->
        raise ArgumentError,
              "No allowed paths configured. Set PYRE_CLIENT_ALLOWED_PATHS environment variable " <>
                "or pass the :allowed_paths option to for_role/3."

      paths ->
        Enum.map(paths, &Path.expand(&1, expanded_wd))
    end
  end

  defp paths_description(working_dir, allowed_paths) do
    dirs = Enum.join(allowed_paths, ", ")

    "Working directory: #{working_dir}. Accessible directories: #{dirs}. " <>
      "Relative paths resolve from the working directory. " <>
      "Use absolute paths to access files in accessible directories outside the working directory."
  end

  # --- Tool Definitions ---

  defp read_file_tool(working_dir, allowed_paths) do
    ReqLLM.Tool.new!(
      name: "read_file",
      description:
        "Read the contents of a file. Path can be absolute or relative to the working directory. #{paths_description(working_dir, allowed_paths)}",
      parameter_schema: [
        path: [
          type: :string,
          required: true,
          doc: "File path (absolute or relative to working directory)"
        ]
      ],
      callback: fn %{path: path} ->
        full_path = resolve_path!(path, working_dir, allowed_paths)

        case File.read(full_path) do
          {:ok, content} -> {:ok, content}
          {:error, reason} -> {:ok, "Error: #{reason}"}
        end
      end
    )
  end

  defp write_file_tool(working_dir, allowed_paths) do
    ReqLLM.Tool.new!(
      name: "write_file",
      description:
        "Write content to a file. Path can be absolute or relative to the working directory. Creates parent directories if needed. #{paths_description(working_dir, allowed_paths)}",
      parameter_schema: [
        path: [
          type: :string,
          required: true,
          doc: "File path (absolute or relative to working directory)"
        ],
        content: [type: :string, required: true, doc: "Complete file content to write"]
      ],
      callback: fn %{path: path, content: content} ->
        full_path = resolve_path!(path, working_dir, allowed_paths)
        File.mkdir_p!(Path.dirname(full_path))

        case File.write(full_path, content) do
          :ok -> {:ok, "Written: #{path}"}
          {:error, reason} -> {:ok, "Error: #{reason}"}
        end
      end
    )
  end

  defp list_directory_tool(working_dir, allowed_paths) do
    ReqLLM.Tool.new!(
      name: "list_directory",
      description:
        "List files and directories at the given path. Set recursive to true to list the full directory tree (directories shown with trailing /). #{paths_description(working_dir, allowed_paths)}",
      parameter_schema: [
        path: [
          type: :string,
          required: true,
          doc: "Directory path (absolute or relative to working directory)"
        ],
        recursive: [
          type: :boolean,
          required: false,
          doc: "List directory tree recursively. Default: false"
        ]
      ],
      callback: fn params ->
        full_path = resolve_path!(params.path, working_dir, allowed_paths)
        recursive? = Map.get(params, :recursive, false)

        if recursive? do
          list_recursive(full_path, full_path)
        else
          case File.ls(full_path) do
            {:ok, entries} -> {:ok, entries |> Enum.sort() |> Enum.join("\n")}
            {:error, reason} -> {:ok, "Error: #{reason}"}
          end
        end
      end
    )
  end

  defp list_recursive(dir, base) do
    case File.ls(dir) do
      {:ok, entries} ->
        lines =
          entries
          |> Enum.sort()
          |> Enum.flat_map(fn entry ->
            full = Path.join(dir, entry)
            relative = Path.relative_to(full, base)

            if File.dir?(full) do
              case list_recursive(full, base) do
                {:ok, ""} -> [relative <> "/"]
                {:ok, children} -> [relative <> "/" | String.split(children, "\n")]
              end
            else
              [relative]
            end
          end)

        {:ok, truncate(Enum.join(lines, "\n"))}

      {:error, reason} ->
        {:ok, "Error: #{reason}"}
    end
  end

  defp run_command_tool(working_dir, allowed_commands, allowed_paths) do
    ReqLLM.Tool.new!(
      name: "run_command",
      description:
        "Run a shell command in the working directory. Allowed commands: #{Enum.join(allowed_commands, ", ")}. " <>
          "Use the optional cwd parameter to run the command in a different directory (validated against allowed paths). " <>
          "#{paths_description(working_dir, allowed_paths)}",
      parameter_schema: [
        command: [type: :string, required: true, doc: "Shell command to execute"],
        cwd: [
          type: :string,
          required: false,
          doc:
            "Working directory for the command (absolute or relative to working directory). Defaults to working directory."
        ]
      ],
      callback: fn params ->
        validate_command!(params.command, allowed_commands)

        cwd =
          case Map.get(params, :cwd) do
            nil -> working_dir
            dir -> resolve_path!(dir, working_dir, allowed_paths)
          end

        {output, code} =
          System.cmd("sh", ["-c", params.command],
            cd: cwd,
            stderr_to_stdout: true,
            env: [{"MIX_ENV", "dev"}]
          )

        result =
          if code == 0 do
            truncate(output)
          else
            "Exit code #{code}:\n#{truncate(output)}"
          end

        {:ok, result}
      end
    )
  end

  # --- Safety ---

  @doc false
  def resolve_path!(relative_path, working_dir, allowed_paths)
      when is_binary(working_dir) and is_list(allowed_paths) do
    full_path = Path.expand(relative_path, working_dir)

    allowed? =
      Enum.any?(allowed_paths, fn base ->
        expanded = Path.expand(base)
        full_path == expanded or String.starts_with?(full_path, expanded <> "/")
      end)

    if !allowed? do
      raise ArgumentError, "Path traversal blocked: #{relative_path}"
    end

    full_path
  end

  def resolve_path!(relative_path, base_paths) when is_list(base_paths) do
    resolve_path!(relative_path, hd(base_paths), base_paths)
  end

  def resolve_path!(relative_path, working_dir) when is_binary(working_dir) do
    resolve_path!(relative_path, working_dir, [working_dir])
  end

  defp validate_command!(command, allowed_commands) do
    trimmed = String.trim(command)

    allowed? =
      Enum.any?(allowed_commands, fn prefix ->
        trimmed == prefix or String.starts_with?(trimmed, prefix <> " ")
      end)

    if !allowed? do
      raise ArgumentError,
            "Command not allowed: #{trimmed}. Allowed: #{Enum.join(allowed_commands, ", ")}"
    end
  end

  defp truncate(text) when byte_size(text) > @max_output_bytes do
    String.slice(text, 0, @max_output_bytes) <> "\n...(truncated)"
  end

  defp truncate(text), do: text
end
