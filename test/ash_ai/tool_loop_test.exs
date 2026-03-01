# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.ToolLoopTest do
  use ExUnit.Case, async: true

  alias AshAi.ToolLoop
  alias ReqLLM.Context

  defmodule TestResource do
    use Ash.Resource,
      domain: AshAi.ToolLoopTest.TestDomain,
      data_layer: Ash.DataLayer.Ets

    ets do
      private?(true)
    end

    actions do
      default_accept([:*])

      action :echo, :string do
        argument :message, :string, allow_nil?: true

        run fn input, _ctx ->
          {:ok, "echo: #{input.arguments.message || "ok"}"}
        end
      end
    end
  end

  defmodule TestDomain do
    use Ash.Domain, extensions: [AshAi]

    resources do
      resource TestResource
    end

    tools do
      tool :echo_tool, TestResource, :echo
    end
  end

  defmodule FakeReqLLMStreamError do
    def stream_text(_model, _messages, _opts \\ []), do: {:error, :stream_failed}
  end

  defmodule FakeReqLLMMalformedToolArguments do
    def stream_text(_model, _messages, _opts \\ []) do
      count = Process.get({__MODULE__, :call_count}, 0)
      Process.put({__MODULE__, :call_count}, count + 1)

      if count == 0 do
        {:ok,
         %ReqLLM.StreamResponse{
           stream: [
             %ReqLLM.StreamChunk{
               type: :tool_call,
               name: "echo_tool",
               arguments: "{not_valid_json",
               metadata: %{}
             },
             ReqLLM.StreamChunk.meta(%{finish_reason: :tool_calls})
           ],
           metadata_handle: :ignored,
           cancel: fn -> :ok end,
           model: "openai:gpt-4o",
           context: ReqLLM.Context.new([])
         }}
      else
        {:ok,
         %ReqLLM.StreamResponse{
           stream: [
             ReqLLM.StreamChunk.text("done"),
             ReqLLM.StreamChunk.meta(%{finish_reason: :stop})
           ],
           metadata_handle: :ignored,
           cancel: fn -> :ok end,
           model: "openai:gpt-4o",
           context: ReqLLM.Context.new([])
         }}
      end
    end
  end

  test "run/2 returns {:error, reason} when req_llm.stream_text fails" do
    messages = [Context.user("hello")]

    assert {:error, :stream_failed} =
             ToolLoop.run(messages,
               actions: [{TestResource, :*}],
               model: "openai:gpt-4o",
               req_llm: FakeReqLLMStreamError
             )
  end

  test "stream/2 emits error event and done result when req_llm.stream_text fails" do
    messages = [Context.user("hello")]

    events =
      ToolLoop.stream(messages,
        actions: [{TestResource, :*}],
        model: "openai:gpt-4o",
        req_llm: FakeReqLLMStreamError
      )
      |> Enum.to_list()

    assert Enum.any?(events, &match?({:error, :stream_failed}, &1))
    assert match?({:done, %ToolLoop.Result{}}, List.last(events))
  end

  test "stream/2 does not crash on invalid tool argument JSON and returns tool error" do
    Process.delete({FakeReqLLMMalformedToolArguments, :call_count})
    messages = [Context.user("trigger tool")]

    events =
      ToolLoop.stream(messages,
        actions: [{TestResource, :*}],
        model: "openai:gpt-4o",
        req_llm: FakeReqLLMMalformedToolArguments
      )
      |> Enum.to_list()

    assert Enum.any?(events, fn
             {:tool_result, %{result: {:error, content}}} ->
               is_binary(content) && content =~ "Invalid tool arguments JSON"

             _ ->
               false
           end)

    assert match?({:done, %ToolLoop.Result{}}, List.last(events))
  end
end
