defmodule PyreClient.Actions.LLM do
  @moduledoc """
  Shared LLM calling infrastructure for action modules.

  Routes based on backend capability (mirrors pyre_lib's Helpers.call_llm/4):
  - CLI backends (manages_tool_loop? = true): direct chat/4
  - ReqLLM (manages_tool_loop? = false): AgenticLoop
  - No tools + streaming: stream/3
  - No tools + no streaming: generate/3
  """

  @doc "Execute an LLM call using the context. Returns {:ok, text} or {:error, reason}."
  # When the Runner has already completed the LLM call (e.g., after an
  # interactive loop), it puts the result text into context. Return it
  # directly so action modules don't double-call the LLM.
  def call(%{llm_result_text: text}) when is_binary(text), do: {:ok, text}

  def call(
        %{backend: backend, model: model, tools: tools, opts: opts, output_fn: output_fn} =
          _context
      ) do
    result =
      cond do
        tools != [] and manages_tool_loop?(backend) ->
          backend.chat(
            model,
            context_messages(opts),
            tools,
            Keyword.put(opts, :output_fn, output_fn)
          )

        tools != [] ->
          log_fn = fn msg -> output_fn.(msg <> "\n") end

          PyreClient.Tools.AgenticLoop.run(
            backend,
            model,
            context_messages(opts),
            tools,
            streaming: Keyword.get(opts, :streaming, false),
            output_fn: output_fn,
            log_fn: log_fn,
            verbose: Keyword.get(opts, :verbose, false)
          )

        Keyword.get(opts, :streaming, true) ->
          backend.stream(model, context_messages(opts), Keyword.put(opts, :output_fn, output_fn))

        true ->
          backend.generate(model, context_messages(opts), opts)
      end

    case result do
      {:ok, text} when is_binary(text) -> {:ok, text}
      {:ok, response} when is_map(response) -> {:ok, extract_text(response)}
      {:error, _} = error -> error
    end
  end

  defp context_messages(opts), do: Keyword.get(opts, :messages, [])

  defp manages_tool_loop?(backend) do
    function_exported?(backend, :manages_tool_loop?, 0) and backend.manages_tool_loop?()
  end

  defp extract_text(%{message: %{content: content}}) when is_list(content) do
    content
    |> Enum.filter(fn part -> Map.get(part, :type) == :text end)
    |> Enum.map_join("", fn part -> Map.get(part, :text, "") end)
  end

  defp extract_text(response), do: inspect(response)
end
