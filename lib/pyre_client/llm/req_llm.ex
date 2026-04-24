defmodule PyreClient.LLM.ReqLLM do
  @moduledoc """
  Default LLM implementation using ReqLLM.

  Provides generate, stream, and chat functions that are provider-agnostic.

  - `generate/3` and `stream/3` return `{:ok, text}` for simple text-only flows.
  - `chat/4` returns `{:ok, ReqLLM.Response.t()}` for tool-use flows that need
    the full response (tool_calls, finish_reason, updated context).
  """

  use PyreClient.LLM

  @impl true
  def generate(model, messages, opts \\ []) do
    context = build_reqllm_context(messages)
    req_opts = Keyword.delete(opts, :output_fn)

    case ReqLLM.generate_text(model, context, req_opts) do
      {:ok, response} -> {:ok, ReqLLM.Response.text(response)}
      {:error, _} = error -> error
    end
  end

  @impl true
  def stream(model, messages, opts \\ []) do
    output_fn = Keyword.get(opts, :output_fn, &IO.write/1)
    context = build_reqllm_context(messages)
    req_opts = Keyword.delete(opts, :output_fn)

    case ReqLLM.stream_text(model, context, req_opts) do
      {:ok, response} ->
        text =
          response
          |> ReqLLM.StreamResponse.tokens()
          |> Stream.each(output_fn)
          |> Enum.join("")

        {:ok, text}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def chat(model, messages, tools, opts \\ []) do
    streaming? = Keyword.get(opts, :streaming, false)
    output_fn = Keyword.get(opts, :output_fn, &IO.write/1)

    context =
      case messages do
        %ReqLLM.Context{} -> messages
        msgs when is_list(msgs) -> build_reqllm_context(msgs)
      end

    req_opts = [tools: tools] ++ Keyword.drop(opts, [:streaming, :output_fn, :tools])

    if streaming? do
      chat_streaming(model, context, req_opts, output_fn)
    else
      chat_non_streaming(model, context, req_opts)
    end
  end

  defp chat_non_streaming(model, context, req_opts) do
    case ReqLLM.generate_text(model, context, req_opts) do
      {:ok, %ReqLLM.Response{}} = ok -> ok
      {:error, _} = error -> error
    end
  end

  defp chat_streaming(model, context, req_opts, output_fn) do
    case ReqLLM.stream_text(model, context, req_opts) do
      {:ok, stream_response} ->
        ReqLLM.StreamResponse.process_stream(stream_response, on_result: output_fn)

      {:error, _} = error ->
        error
    end
  end

  defp build_reqllm_context(messages) do
    msgs =
      Enum.map(messages, fn
        %{role: :system, content: content} -> ReqLLM.Context.system(content)
        %{role: :user, content: content} when is_list(content) -> ReqLLM.Context.user(content)
        %{role: :user, content: content} -> ReqLLM.Context.user(content)
        %{role: :assistant, content: content} -> ReqLLM.Context.assistant(content)
      end)

    ReqLLM.Context.new(msgs)
  end
end
