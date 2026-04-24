defmodule PyreClient.Tools.AgenticLoop do
  @moduledoc """
  Multi-turn tool-use conversation loop.

  Repeatedly calls the LLM with tools, executes any tool calls from the
  response, appends results to the conversation, and continues until the
  LLM produces a final text answer or the iteration limit is reached.
  """

  @max_iterations 250
  @default_receive_timeout 300_000

  @doc """
  Runs the agentic loop until the LLM produces a final answer.

  Returns `{:ok, final_text}` with the accumulated text from all turns.

  ## Options

    * `:streaming` - Stream tokens via `output_fn`. Default `false`.
    * `:output_fn` - Token callback for streaming. Default `&IO.write/1`.
    * `:max_iterations` - Max tool-use turns. Default `250`.
    * `:log_fn` - Function for status/progress messages. Default `&IO.puts/1`.
    * `:verbose` - Log tool calls. Default `false`.
    * `:receive_timeout` - Per-chunk timeout in ms. Default `300_000` (5 min).
  """
  @spec run(module(), String.t(), [map()], [ReqLLM.Tool.t()], keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def run(llm_module, model, messages, tools, opts \\ []) do
    max_iter = Keyword.get(opts, :max_iterations, @max_iterations)
    streaming? = Keyword.get(opts, :streaming, false)
    output_fn = Keyword.get(opts, :output_fn, &IO.write/1)
    log_fn = Keyword.get(opts, :log_fn, &IO.puts/1)
    verbose? = Keyword.get(opts, :verbose, false)
    receive_timeout = Keyword.get(opts, :receive_timeout, @default_receive_timeout)

    config = %{
      max_iter: max_iter,
      streaming: streaming?,
      output_fn: output_fn,
      log_fn: log_fn,
      verbose: verbose?,
      receive_timeout: receive_timeout
    }

    loop(llm_module, model, messages, tools, 0, config, "")
  end

  defp loop(
         _llm,
         _model,
         _messages,
         _tools,
         iteration,
         %{max_iter: max_iter} = config,
         accumulated
       )
       when iteration >= max_iter do
    config.log_fn.(
      "\n[warning] Reached maximum tool-use iterations (#{max_iter}). " <>
        "The agent may not have finished its work. " <>
        "Increase :max_iterations if needed."
    )

    {:ok, accumulated <> "\n\n(Reached maximum tool-use iterations)"}
  end

  defp loop(llm_module, model, messages, tools, iteration, config, accumulated) do
    # Force non-streaming for tool-use chat calls. ReqLLM's streaming path has
    # a bug where large tool call arguments arrive with empty args.
    chat_opts = [
      streaming: false,
      receive_timeout: config.receive_timeout
    ]

    case llm_module.chat(model, messages, tools, chat_opts) do
      {:ok, response} ->
        classified = ReqLLM.Response.classify(response)

        handle_classified(
          classified,
          response,
          llm_module,
          model,
          tools,
          iteration,
          config,
          accumulated
        )

      {:error, _} = error ->
        error
    end
  end

  defp handle_classified(
         %{type: :final_answer, text: text},
         _response,
         _llm,
         _model,
         _tools,
         _iteration,
         config,
         accumulated
       ) do
    if text != "", do: config.output_fn.(text)
    {:ok, accumulated <> text}
  end

  defp handle_classified(
         %{type: :tool_calls, text: text, tool_calls: tool_calls},
         response,
         llm_module,
         model,
         tools,
         iteration,
         config,
         accumulated
       ) do
    if text != "", do: config.output_fn.(text)
    log_tool_calls(tool_calls, iteration, config)

    updated_context = execute_tools(response.context, tool_calls, tools, config)

    loop(llm_module, model, updated_context, tools, iteration + 1, config, accumulated <> text)
  end

  # --- Tool Execution ---

  defp execute_tools(context, tool_calls, tools, config) do
    Enum.reduce(tool_calls, context, fn tool_call, ctx ->
      name = extract_tool_name(tool_call)
      id = extract_tool_id(tool_call)
      args = extract_tool_args(tool_call)

      result =
        case find_and_execute(name, args, tools) do
          {:ok, value} ->
            if config.verbose, do: log_tool_result(name, :ok, value, config.log_fn)
            value

          {:error, error} ->
            error_msg = format_tool_error(name, error, tools)
            config.log_fn.("[tool error] #{name}: #{error_msg}")
            error_msg
        end

      ReqLLM.Context.append(ctx, ReqLLM.Context.tool_result(id, result))
    end)
  end

  defp find_and_execute(name, args, tools) do
    case Enum.find(tools, fn t -> t.name == name end) do
      nil -> {:error, {:not_found, name}}
      tool -> ReqLLM.Tool.execute(tool, args)
    end
  end

  # --- Error Formatting ---

  defp format_tool_error(name, {:not_found, _}, tools) do
    available = tools |> Enum.map_join(", ", & &1.name)
    "Error: Tool '#{name}' not found. Available tools: #{available}"
  end

  defp format_tool_error(name, error, tools) do
    reason = extract_error_reason(error)
    schema_hint = tool_schema_hint(name, tools)
    "Error: #{reason}#{schema_hint}"
  end

  defp extract_error_reason(%{reason: reason}) when is_binary(reason), do: reason
  defp extract_error_reason(error) when is_binary(error), do: error

  defp extract_error_reason(error) do
    if is_exception(error), do: Exception.message(error), else: inspect(error)
  end

  defp tool_schema_hint(name, tools) do
    case Enum.find(tools, fn t -> t.name == name end) do
      nil ->
        ""

      tool ->
        params =
          tool.parameter_schema
          |> Enum.map_join("\n", fn {key, opts} ->
            type = Keyword.get(opts, :type, :any)
            required? = Keyword.get(opts, :required, false)
            suffix = if required?, do: " (required)", else: ""
            "  - #{key}: #{type}#{suffix}"
          end)

        "\n\nExpected parameters for '#{name}':\n#{params}\n\nEnsure all required parameters are provided with correct types."
    end
  end

  # --- Extraction Helpers ---

  defp extract_tool_name(%ReqLLM.ToolCall{function: %{name: name}}), do: name
  defp extract_tool_name(%{name: name}), do: name

  defp extract_tool_id(%ReqLLM.ToolCall{id: id}), do: id
  defp extract_tool_id(%{id: id}), do: id

  defp extract_tool_args(%ReqLLM.ToolCall{function: %{arguments: args}}) when is_binary(args),
    do: Jason.decode!(args)

  defp extract_tool_args(%ReqLLM.ToolCall{function: %{arguments: args}}), do: args
  defp extract_tool_args(%{arguments: args}) when is_binary(args), do: Jason.decode!(args)
  defp extract_tool_args(%{arguments: args}), do: args

  # --- Logging ---

  defp log_tool_calls(tool_calls, iteration, config) do
    Enum.each(tool_calls, fn tc ->
      name = extract_tool_name(tc)
      args = extract_tool_args(tc)
      arg_keys = if is_map(args), do: Map.keys(args), else: []
      empty? = args == %{} or args == nil

      suffix = tool_log_suffix(name, args)

      config.log_fn.(
        "[tool #{iteration + 1}] #{name}(#{format_arg_summary(arg_keys, empty?)})#{suffix}"
      )

      if config.verbose and not empty? do
        Enum.each(args, fn {k, v} ->
          display =
            if is_binary(v) and byte_size(v) > 200,
              do: "#{String.slice(v, 0, 200)}...(#{byte_size(v)} bytes)",
              else: inspect(v)

          config.log_fn.("[tool #{iteration + 1}]   #{k}: #{display}")
        end)
      end
    end)
  end

  defp format_arg_summary(_keys, true), do: "EMPTY ARGS"
  defp format_arg_summary(keys, false), do: Enum.join(keys, ", ")

  defp tool_log_suffix(name, args) when is_map(args) do
    value =
      case name do
        "run_command" -> Map.get(args, "command")
        "list_directory" -> Map.get(args, "path")
        "read_file" -> Map.get(args, "path")
        "write_file" -> Map.get(args, "path")
        _ -> nil
      end

    if value, do: ": #{value}", else: ""
  end

  defp tool_log_suffix(_name, _args), do: ""

  defp log_tool_result(name, :ok, value, log_fn) when is_binary(value) do
    display = if byte_size(value) > 200, do: "#{String.slice(value, 0, 200)}...", else: value
    log_fn.("[tool result] #{name}: #{display}")
  end

  defp log_tool_result(name, :ok, value, log_fn) do
    log_fn.("[tool result] #{name}: #{inspect(value, limit: 5)}")
  end
end
