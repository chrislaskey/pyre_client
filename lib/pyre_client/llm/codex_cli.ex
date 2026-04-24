defmodule PyreClient.LLM.CodexCLI do
  @moduledoc """
  LLM backend that delegates to the OpenAI `codex` CLI subprocess.

  Uses `codex exec --json` for non-interactive LLM calls.
  When called with tools via `chat/4`, the CLI runs its own internal
  agentic loop, bypassing Pyre's `AgenticLoop` entirely.

  Key differences from ClaudeCLI:
  - Command structure: `codex exec --json "prompt"` (not `-p prompt`)
  - NDJSON schema: text is in `item.completed` events with `type: "agent_message"`
  - No session resumption support in v1
  """

  use PyreClient.LLM

  require Logger

  @default_timeout 600_000

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
    {_system_prompt, user_prompt} = extract_prompts(messages)

    args = ["exec", "--json"] ++ build_model_args(cli_model) ++ [user_prompt]

    case run_cli(args, timeout) do
      {:ok, output} -> parse_ndjson_result(output)
      {:error, _} = error -> error
    end
  end

  # --- stream/3 ---

  @impl true
  def stream(model, messages, opts \\ []) do
    output_fn = Keyword.get(opts, :output_fn, &IO.write/1)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    cli_model = map_model(model)
    {_system_prompt, user_prompt} = extract_prompts(messages)

    args = ["exec", "--json"] ++ build_model_args(cli_model) ++ [user_prompt]

    run_cli_streaming(args, output_fn, timeout)
  end

  # --- chat/4 ---

  @impl true
  def chat(model, messages, _tools, opts \\ []) do
    streaming? = Keyword.get(opts, :streaming, false)
    output_fn = Keyword.get(opts, :output_fn, &IO.write/1)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    working_dir = Keyword.get(opts, :working_dir)
    cli_model = map_model(model)
    {_system_prompt, user_prompt} = extract_prompts(messages)

    user_prompt = user_prompt <> "\n\n" <> @non_interactive_note

    Logger.info(
      "[CodexCLI] chat/4 model=#{cli_model} streaming=#{streaming?} prompt_len=#{byte_size(user_prompt)}"
    )

    args =
      ["exec", "--json", "--full-auto"] ++
        build_model_args(cli_model) ++
        build_cd_args(working_dir)

    run_opts = []

    if streaming? do
      run_cli_streaming(args ++ [user_prompt], output_fn, timeout, run_opts)
    else
      case run_cli(args ++ [user_prompt], timeout, run_opts) do
        {:ok, output} -> parse_ndjson_result(output)
        {:error, _} = error -> error
      end
    end
  end

  # --- Model Mapping ---

  @doc false
  def map_model("anthropic:claude-haiku" <> _), do: "gpt-4o-mini"
  def map_model("anthropic:claude-sonnet" <> _), do: "gpt-4o"
  def map_model("anthropic:claude-opus" <> _), do: "o3"
  def map_model("haiku"), do: "gpt-4o-mini"
  def map_model("sonnet"), do: "gpt-4o"
  def map_model("opus"), do: "o3"
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

    task =
      Task.async(fn ->
        try do
          env = build_env()
          opts = [stderr_to_stdout: true, env: env] ++ run_opts

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

    case System.find_executable(executable) do
      nil ->
        {:error, :cli_not_found}

      _exe_path ->
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
          "[CodexCLI] exited with code #{code}, output: #{String.slice(accumulated, 0..500)}"
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
      {:ok, %{"type" => "item.completed", "item" => %{"type" => "agent_message", "text" => text}}}
      when is_binary(text) and text != "" ->
        output_fn.(text)
        accumulated <> text

      {:ok, %{"type" => "turn.completed"}} ->
        accumulated

      {:ok, %{"type" => "error", "message" => msg}} when is_binary(msg) ->
        Logger.warning("[CodexCLI] error event: #{msg}")
        accumulated

      {:ok, %{"type" => _}} ->
        accumulated

      _ ->
        accumulated
    end
  end

  # --- NDJSON Parsing (batch) ---

  @doc false
  def parse_ndjson_result(output) do
    trimmed = String.trim(output)

    if trimmed == "" do
      {:error, {:parse_error, "empty output"}}
    else
      result =
        trimmed
        |> String.split("\n", trim: true)
        |> Enum.reduce(nil, fn line, acc ->
          case Jason.decode(line) do
            {:ok,
             %{"type" => "item.completed", "item" => %{"type" => "agent_message", "text" => text}}}
            when is_binary(text) ->
              (acc || "") <> text

            _ ->
              acc
          end
        end)

      case result do
        nil -> {:error, {:parse_error, trimmed}}
        text -> {:ok, text}
      end
    end
  end

  # --- Helpers ---

  defp build_model_args(model) when is_binary(model) and model != "" do
    ["--model", model]
  end

  defp build_model_args(_), do: []

  defp build_cd_args(nil), do: []
  defp build_cd_args(dir), do: ["--cd", dir]

  defp build_env do
    case System.get_env("CODEX_API_KEY") do
      nil -> []
      key -> [{"CODEX_API_KEY", key}]
    end
  end

  defp cli_executable do
    Application.get_env(:pyre_client, :codex_cli_executable, "codex")
  end
end
