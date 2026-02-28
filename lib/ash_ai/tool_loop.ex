# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs.contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.ToolLoop do
  @moduledoc """
  Manages a ReqLLM conversation loop with tool calls.

  This module is the primary orchestration API for tool-enabled conversations.
  """

  alias ReqLLM.Context

  defmodule IterationEvent do
    @moduledoc """
    Event emitted at the start of each iteration in the tool loop.
    """
    defstruct [:iteration, :messages_count, :tool_calls_count]
  end

  defmodule Result do
    @moduledoc """
    Result returned from a completed tool loop.
    """
    defstruct [:messages, :final_text, :iterations, :tool_calls_made]
  end

  @doc """
  Runs the tool loop synchronously.
  """
  def run(messages, opts) do
    opts = AshAi.Options.validate!(opts)
    {tools, registry} = AshAi.Tools.build_tools_and_registry(opts)
    context = build_context(opts)
    model = resolve_model(opts.model, opts)

    run_loop(
      opts.req_llm,
      model,
      messages,
      tools,
      registry,
      context,
      1,
      opts.max_iterations,
      []
    )
  end

  @doc """
  Streams events from the tool loop.

  Events:
  - `{:content, text}`
  - `{:tool_call, %{id: id, name: name, arguments: args}}`
  - `{:tool_result, %{id: id, result: result}}`
  - `{:iteration, %IterationEvent{}}`
  - `{:done, %Result{}}`
  """
  def stream(messages, opts) do
    Stream.resource(
      fn -> init_stream(messages, opts) end,
      &next_stream_chunk/1,
      &cleanup_stream/1
    )
  end

  defp init_stream(messages, opts) do
    opts = AshAi.Options.validate!(opts)
    {tools, registry} = AshAi.Tools.build_tools_and_registry(opts)
    context = build_context(opts)
    model = resolve_model(opts.model, opts)

    %{
      req_llm: opts.req_llm,
      model: model,
      messages: messages,
      tools: tools,
      registry: registry,
      context: context,
      iteration: 1,
      max_iterations: opts.max_iterations,
      tool_calls_made: [],
      state: :running
    }
  end

  defp next_stream_chunk(%{state: :done} = state), do: {:halt, state}

  defp next_stream_chunk(state) do
    case stream_iteration(state) do
      {:continue, events, new_state} ->
        {events, new_state}

      {:done, events, result} ->
        {events ++ [{:done, result}], %{state | state: :done}}
    end
  end

  defp cleanup_stream(_state), do: :ok

  defp stream_iteration(state) do
    %{
      req_llm: req_llm,
      model: model,
      messages: messages,
      tools: tools,
      registry: registry,
      context: context,
      iteration: iteration,
      max_iterations: max_iterations,
      tool_calls_made: tool_calls_made
    } = state

    if iteration > max_iterations do
      result = %Result{
        messages: messages,
        final_text: "",
        iterations: iteration - 1,
        tool_calls_made: tool_calls_made
      }

      {:done, [{:error, :max_iterations_reached}], result}
    else
      {:ok, stream_response} = req_llm.stream_text(model, messages, tools: tools)
      chunks = Enum.to_list(stream_response.stream)
      content_events = content_events(chunks)

      classification =
        stream_response
        |> Map.put(:stream, chunks)
        |> ReqLLM.StreamResponse.classify()

      if classification.type == :tool_calls do
        tool_calls =
          Enum.map(classification.tool_calls, fn tool_call ->
            %{
              id: Map.get(tool_call, :id) || generate_tool_id(),
              name: Map.fetch!(tool_call, :name),
              arguments: Map.get(tool_call, :arguments, %{})
            }
          end)

        assistant_with_tools =
          Context.assistant(classification.text || "", tool_calls: tool_calls)

        messages = messages ++ [assistant_with_tools]

        {messages, tool_events} = run_tools_streaming(tool_calls, messages, registry, context)

        new_state = %{
          state
          | messages: messages,
            iteration: iteration + 1,
            tool_calls_made: tool_calls_made ++ tool_calls
        }

        {:continue,
         content_events ++
           Enum.map(tool_calls, &{:tool_call, &1}) ++
           tool_events ++
           [{:iteration, %IterationEvent{iteration: iteration + 1}}], new_state}
      else
        messages =
          if classification.text not in [nil, ""] do
            messages ++ [Context.assistant(classification.text)]
          else
            messages
          end

        result = %Result{
          messages: messages,
          final_text: classification.text || "",
          iterations: iteration,
          tool_calls_made: tool_calls_made
        }

        {:done, content_events, result}
      end
    end
  end

  defp content_events(chunks) do
    chunks
    |> Enum.filter(&(&1.type == :content))
    |> Enum.map(fn chunk -> {:content, chunk.text || ""} end)
  end

  defp run_tools_streaming(tool_calls, messages, registry, ctx) do
    Enum.reduce(tool_calls, {messages, []}, fn tool_call, {msgs, events} ->
      case run_single_tool(tool_call, registry, ctx) do
        {result, content} ->
          {
            msgs ++ [Context.tool_result(tool_call.id, content)],
            events ++ [{:tool_result, %{id: tool_call.id, result: result}}]
          }
      end
    end)
  end

  defp build_context(opts) do
    %{
      actor: opts.actor,
      tenant: opts.tenant,
      context: opts.context || %{},
      tool_callbacks: %{
        on_tool_start: opts.on_tool_start,
        on_tool_end: opts.on_tool_end
      }
    }
  end

  defp resolve_model(model, opts) when is_function(model, 1),
    do: resolve_model(model.(opts), opts)

  defp resolve_model(model, _opts) when is_function(model, 0), do: model.()
  defp resolve_model(model, _opts), do: model

  defp run_loop(
         req_llm,
         model,
         messages,
         tools,
         registry,
         context,
         iteration,
         max_iterations,
         tool_calls_made
       ) do
    if iteration > max_iterations do
      {:error, :max_iterations_reached}
    else
      {:ok, stream_response} = req_llm.stream_text(model, messages, tools: tools)
      classification = ReqLLM.StreamResponse.classify(stream_response)

      if classification.type == :tool_calls do
        tool_calls =
          Enum.map(classification.tool_calls, fn tool_call ->
            %{
              id: Map.get(tool_call, :id) || generate_tool_id(),
              name: Map.fetch!(tool_call, :name),
              arguments: Map.get(tool_call, :arguments, %{})
            }
          end)

        assistant_with_tools =
          Context.assistant(classification.text || "", tool_calls: tool_calls)

        messages = messages ++ [assistant_with_tools]
        messages = run_tools(tool_calls, messages, registry, context)

        run_loop(
          req_llm,
          model,
          messages,
          tools,
          registry,
          context,
          iteration + 1,
          max_iterations,
          tool_calls_made ++ tool_calls
        )
      else
        messages =
          if classification.text not in [nil, ""] do
            messages ++ [Context.assistant(classification.text)]
          else
            messages
          end

        {:ok,
         %Result{
           messages: messages,
           final_text: classification.text || "",
           iterations: iteration,
           tool_calls_made: tool_calls_made
         }}
      end
    end
  end

  defp run_tools(tool_calls, messages, registry, ctx) do
    Enum.reduce(tool_calls, messages, fn tool_call, msgs ->
      {_, content} = run_single_tool(tool_call, registry, ctx)
      msgs ++ [Context.tool_result(tool_call.id, content)]
    end)
  end

  defp run_single_tool(tool_call, registry, ctx) do
    fun = Map.get(registry, tool_call.name)

    if is_nil(fun) do
      content = Jason.encode!(%{error: "Unknown tool: #{tool_call.name}"})
      {{:error, content}, content}
    else
      args =
        case tool_call.arguments do
          s when is_binary(s) -> Jason.decode!(s)
          m when is_map(m) -> m
          _ -> %{}
        end

      result =
        try do
          fun.(args, ctx)
        rescue
          e ->
            {:error, Jason.encode!(%{error: Exception.message(e)})}
        end

      content =
        case result do
          {:ok, content, _raw} -> content
          {:error, content} -> content
        end

      {result, content}
    end
  end

  defp generate_tool_id do
    "call_#{:erlang.unique_integer([:positive])}"
  end
end
