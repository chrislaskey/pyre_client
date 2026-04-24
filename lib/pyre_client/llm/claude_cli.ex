defmodule PyreClient.LLM.ClaudeCLI do
  @moduledoc """
  LLM backend that delegates to the `claude` CLI subprocess.

  Uses `claude -p` (print mode) for non-interactive LLM calls.
  When called with tools via `chat/4`, the CLI runs its own internal
  agentic loop with built-in tools (Bash, Read, Edit, Write, Glob, Grep),
  bypassing Pyre's `AgenticLoop` entirely.

  ## Prerequisites

  The `claude` CLI must be installed and on PATH:

      npm install -g @anthropic-ai/claude-code

  ## Configuration

      # Select as default backend via env var:
      PYRE_LLM_BACKEND=claude_cli

      # Or via config:
      config :pyre_client, llm_backend: :claude_cli
  """

  use PyreClient.LLM

  require Logger

  @default_timeout 600_000
  @default_max_turns 500

  @non_interactive_note "Note: This is a non-interactive session running inside an automated " <>
                          "pipeline. If you have questions or need clarification before " <>
                          "proceeding, include them clearly at the end of your response — " <>
                          "the user can reply by resuming this session."

  @impl true
  def manages_tool_loop?, do: true

  # --- generate/3 ---

  @impl true
  def generate(model, messages, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    cli_model = map_model(model)
    {system_prompt, user_prompt} = extract_prompts(messages)

    args =
      build_base_args(cli_model, system_prompt) ++
        ["--output-format", "json", "--max-turns", "1", "-p", user_prompt]

    case run_cli(args, timeout) do
      {:ok, output} -> parse_json_result(output)
      {:error, _} = error -> error
    end
  end

  # --- stream/3 ---

  @impl true
  def stream(model, messages, opts \\ []) do
    output_fn = Keyword.get(opts, :output_fn, &IO.write/1)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    cli_model = map_model(model)
    {system_prompt, user_prompt} = extract_prompts(messages)

    args =
      build_base_args(cli_model, system_prompt) ++
        [
          "--output-format",
          "stream-json",
          "--verbose",
          "--include-partial-messages",
          "--max-turns",
          "1",
          "-p",
          user_prompt
        ]

    run_cli_streaming(args, output_fn, timeout)
  end

  # --- chat/4 ---

  @impl true
  def chat(model, messages, _tools, opts \\ []) do
    streaming? = Keyword.get(opts, :streaming, false)
    output_fn = Keyword.get(opts, :output_fn, &IO.write/1)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    max_turns = Keyword.get(opts, :max_turns, @default_max_turns)
    working_dir = Keyword.get(opts, :working_dir)
    add_dirs = Keyword.get(opts, :add_dirs, [])
    cli_model = map_model(model)
    {system_prompt, user_prompt} = extract_prompts(messages)

    # Append the non-interactive context note on the opening call of a session so
    # Claude surfaces questions explicitly rather than silently making assumptions.
    # Not injected on --resume calls since the session already holds the note.
    user_prompt =
      if opts[:session_id] do
        user_prompt <> "\n\n" <> @non_interactive_note
      else
        user_prompt
      end

    Logger.info(
      "[ClaudeCLI] chat/4 model=#{cli_model} streaming=#{streaming?} prompt_len=#{byte_size(user_prompt)}"
    )

    args =
      build_base_args(cli_model, system_prompt) ++
        [
          "--permission-mode",
          "bypassPermissions",
          "--allowedTools",
          "Bash,Read,Edit,Write,Glob,Grep"
        ] ++
        session_persistence_args(opts) ++
        [
          "--max-turns",
          to_string(max_turns)
        ] ++
        build_add_dir_args(add_dirs)

    run_opts = if working_dir, do: [cd: working_dir], else: []

    if streaming? do
      streaming_args =
        args ++
          [
            "--output-format",
            "stream-json",
            "--verbose",
            "-p",
            user_prompt
          ]

      run_cli_streaming(streaming_args, output_fn, timeout, run_opts)
    else
      batch_args = args ++ ["--output-format", "json", "-p", user_prompt]

      case run_cli(batch_args, timeout, run_opts) do
        {:ok, output} -> parse_json_result(output)
        {:error, _} = error -> error
      end
    end
  end

  # --- Model Mapping ---

  @doc false
  def map_model("anthropic:claude-haiku" <> _), do: "haiku"
  def map_model("anthropic:claude-sonnet" <> _), do: "sonnet"
  def map_model("anthropic:claude-opus" <> _), do: "opus"
  def map_model("haiku"), do: "haiku"
  def map_model("sonnet"), do: "sonnet"
  def map_model("opus"), do: "opus"
  def map_model(other), do: other

  # --- Prompt Extraction ---

  @doc false
  def extract_prompts(messages) when is_list(messages) do
    system_parts =
      messages
      |> Enum.filter(fn %{role: role} -> role == :system end)
      |> Enum.map_join("\n\n", fn %{content: content} -> to_text(content) end)

    user_parts =
      messages
      |> Enum.filter(fn %{role: role} -> role == :user end)
      |> Enum.map_join("\n\n", fn %{content: content} -> to_text(content) end)

    # Embed persona/system instructions directly in the user prompt so
    # Claude Code follows them more reliably. The same content is still
    # passed via --append-system-prompt for system-level positioning.
    user_prompt =
      if system_parts == "" do
        user_parts
      else
        """
        <persona>
        #{system_parts}
        </persona>

        You MUST follow the persona instructions above for the duration of this task. \
        Stay in character, use the output format specified, and do not deviate from the role described.

        #{user_parts}\
        """
      end

    {system_parts, user_prompt}
  end

  def extract_prompts(_other), do: {"", "Please continue."}

  defp to_text(content) when is_binary(content), do: content

  defp to_text(parts) when is_list(parts) do
    parts
    |> Enum.filter(fn p -> is_map(p) and Map.get(p, :type) == :text end)
    |> Enum.map_join("\n", fn p -> p.text end)
  end

  defp to_text(_), do: ""

  # --- CLI Execution (batch) ---

  defp run_cli(args, timeout, run_opts \\ []) do
    executable = cli_executable()
    Logger.debug("[ClaudeCLI] run_cli: #{executable} #{Enum.join(args, " ")}")

    task =
      Task.async(fn ->
        try do
          env = build_env()
          opts = [stderr_to_stdout: true, env: env] ++ run_opts

          # Wrap via shell to redirect stdin from /dev/null.
          # The CLI blocks waiting for stdin EOF otherwise.
          {:ok,
           System.cmd("/bin/sh", ["-c", ~s(exec "$0" "$@" </dev/null), executable | args], opts)}
        rescue
          _ -> {:error, :cli_not_found}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {:ok, {output, 0}}} ->
        {:ok, output}

      {:ok, {:ok, {_output, 127}}} ->
        {:error, :cli_not_found}

      {:ok, {:ok, {output, exit_code}}} ->
        {:error, {:cli_error, exit_code, output}}

      {:ok, {:error, _} = error} ->
        error

      nil ->
        {:error, :timeout}
    end
  end

  # --- CLI Execution (streaming) ---

  defp run_cli_streaming(args, output_fn, timeout, run_opts \\ []) do
    executable = cli_executable()
    Logger.debug("[ClaudeCLI] run_cli_streaming: #{executable} #{Enum.join(args, " ")}")

    case System.find_executable(executable) do
      nil ->
        {:error, :cli_not_found}

      _exe_path ->
        # Wrap via shell to redirect stdin from /dev/null.
        shell_script = ~s(exec "$0" "$@" </dev/null)
        sh_path = System.find_executable("sh")

        cd_opts =
          case Keyword.get(run_opts, :cd) do
            nil -> []
            dir -> [{:cd, to_charlist(dir)}]
          end

        env_opts =
          case build_env() do
            [] -> []
            env -> [{:env, Enum.map(env, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)}]
          end

        sh_args = ["-c", shell_script, executable | args]

        port_opts =
          [
            :binary,
            :exit_status,
            :use_stdio,
            :stderr_to_stdout,
            {:line, 65_536},
            {:args, sh_args}
          ] ++
            cd_opts ++ env_opts

        port = Port.open({:spawn_executable, sh_path}, port_opts)
        collect_streaming(port, output_fn, timeout, "", "")
    end
  end

  defp collect_streaming(port, output_fn, timeout, accumulated, line_buffer) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        full_line = line_buffer <> line
        accumulated = process_stream_line(full_line, output_fn, accumulated)
        collect_streaming(port, output_fn, timeout, accumulated, "")

      {^port, {:data, {:noeol, partial}}} ->
        collect_streaming(port, output_fn, timeout, accumulated, line_buffer <> partial)

      {^port, {:exit_status, 0}} ->
        {:ok, accumulated}

      {^port, {:exit_status, code}} ->
        Logger.warning(
          "[ClaudeCLI] exited with code #{code}, output: #{String.slice(accumulated, 0..500)}"
        )

        {:error, {:cli_error, code, accumulated}}
    after
      timeout ->
        Port.close(port)
        {:error, :timeout}
    end
  end

  defp process_stream_line(line, output_fn, accumulated) do
    case Jason.decode(line) do
      # stream_event wrapper (--include-partial-messages mode)
      {:ok, %{"type" => "stream_event", "event" => event}} ->
        process_stream_event(event, output_fn, accumulated)

      # Bare SSE events (some CLI versions emit without wrapper)
      {:ok, %{"type" => "content_block_delta"} = event} ->
        process_stream_event(event, output_fn, accumulated)

      # Full assistant message (non-partial mode / --verbose)
      {:ok, %{"type" => "assistant", "message" => %{"content" => content}}} ->
        text =
          content
          |> Enum.filter(fn part -> Map.get(part, "type") == "text" end)
          |> Enum.map_join("", fn part -> Map.get(part, "text", "") end)

        if text != "", do: output_fn.(text)
        accumulated <> text

      # Final result
      {:ok, %{"type" => "result", "result" => text}} when is_binary(text) ->
        text

      _ ->
        accumulated
    end
  end

  defp process_stream_event(
         %{"type" => "content_block_delta", "delta" => %{"type" => "text_delta", "text" => text}},
         output_fn,
         accumulated
       )
       when is_binary(text) and text != "" do
    output_fn.(text)
    accumulated <> text
  end

  defp process_stream_event(_event, _output_fn, accumulated), do: accumulated

  # --- JSON Parsing ---

  @doc false
  def parse_json_result(output) do
    trimmed = String.trim(output)

    cond do
      String.starts_with?(trimmed, "[") ->
        parse_json_array(trimmed)

      trimmed != "" ->
        parse_ndjson(trimmed)

      true ->
        {:error, {:parse_error, "empty output"}}
    end
  end

  defp parse_json_array(text) do
    case Jason.decode(text) do
      {:ok, items} when is_list(items) ->
        case find_result(items) do
          nil -> {:error, {:parse_error, text}}
          result -> {:ok, result}
        end

      _ ->
        {:error, {:parse_error, text}}
    end
  end

  defp parse_ndjson(text) do
    result =
      text
      |> String.split("\n", trim: true)
      |> Enum.reduce(nil, fn line, acc ->
        case Jason.decode(line) do
          {:ok, %{"type" => "result", "result" => result}} when is_binary(result) -> result
          _ -> acc
        end
      end)

    case result do
      nil -> {:error, {:parse_error, text}}
      text -> {:ok, text}
    end
  end

  defp find_result(items) do
    items
    |> Enum.find_value(fn
      %{"type" => "result", "result" => text} when is_binary(text) -> text
      _ -> nil
    end)
  end

  # --- Helpers ---

  defp session_persistence_args(opts) do
    cond do
      resume_id = opts[:resume] -> ["--resume", resume_id]
      session_id = opts[:session_id] -> ["--session-id", session_id]
      true -> ["--no-session-persistence"]
    end
  end

  defp build_add_dir_args([]), do: []

  defp build_add_dir_args(dirs) when is_list(dirs) do
    Enum.flat_map(dirs, fn dir -> ["--add-dir", dir] end)
  end

  defp build_base_args(model, system_prompt) do
    args = ["--model", model]

    if system_prompt == "" do
      args
    else
      args ++ ["--append-system-prompt", system_prompt]
    end
  end

  defp build_env do
    case System.get_env("ANTHROPIC_API_KEY") do
      nil -> []
      key -> [{"ANTHROPIC_API_KEY", key}]
    end
  end

  defp cli_executable do
    Application.get_env(:pyre_client, :claude_cli_executable, "claude")
  end
end
