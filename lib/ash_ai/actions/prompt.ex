# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.Actions.Prompt do
  require Logger

  @prompt_template {"""
                    You are responsible for performing the `<%= @input.action.name %>` action.

                    <%= if @input.action.description do %>
                    # Description
                    <%= @input.action.description %>
                    <% end %>

                    ## Inputs
                    <%= for argument <- @input.action.arguments do %>
                    - <%= argument.name %><%= if argument.description do %>: <%= argument.description %>
                    <% end %>
                    <% end %>
                    """,
                    """
                    # Action Inputs

                    <%= for argument <- @input.action.arguments,
                        {:ok, value} = Ash.ActionInput.fetch_argument(@input, argument.name),
                        {:ok, value} = Ash.Type.dump_to_embedded(argument.type, value, argument.constraints) do %>
                      - <%= argument.name %>: <%= Jason.encode!(value) %>
                    <% end %>
                    """}
  @moduledoc """
  A generic action impl that returns structured outputs from an LLM matching the action return.

  Uses ReqLLM for structured output generation with model specifications as strings.

  ## Example

  ```elixir
  action :analyze_sentiment, :atom do
    constraints one_of: [:positive, :negative]

    description \"\"\"
    Analyzes the sentiment of a given piece of text to determine if it is overall positive or negative.
    \"\"\"

    argument :text, :string do
      allow_nil? false
      description "The text for analysis."
    end

    run prompt("openai:gpt-4o",
      prompt: {"You are a sentiment analyzer", "Analyze: <%= @input.arguments.text %>"}
    )
  end
  ```

  ## Model Specification

  The first argument to `prompt/2` is a model specification string in the format `"provider:model-name"`.
  Valid model strings can be browsed at https://llmdb.xyz.
  Examples: `"openai:gpt-4o"`, `"anthropic:claude-haiku-4-5"`, `"openai:gpt-4o-mini"`.

  ## Options

  - `:prompt` - A custom prompt. Supports multiple formats - see the prompt section below.
  - `:req_llm` - Override the ReqLLM module (useful for testing with mocks).
  - `:tools` - `false`, `true`, or a list of tool names to allow tool-calling in the action.
  - `:max_iterations` - Maximum tool-loop iterations. Defaults to `:infinity` for prompt actions.
  - `:verbose?` - When true, logs tool-loop lifecycle events with `Logger.debug/1`.

  ## Behavior Notes

  - Tool-loop failures are returned as action errors with loop reason details.
  - Unconstrained `:map` return types use a permissive map schema (`type: object`).

  ## Prompt Formats

  The prompt by default is generated using the action and input descriptions. You can provide your own prompt
  via the `prompt` option which supports multiple formats:

  ### Supported Formats

  1. **String (EEx template)**: `"Analyze this: <%= @input.arguments.text %>"`
  2. **{System, User} tuple**: `{"You are an expert", "Analyze: <%= @input.arguments.text %>"}`
  3. **ReqLLM.Context**: Pass a context directly (canonical format)
  4. **List of messages**: Maps with role/content, ReqLLM.Message structs, or mixed
  5. **Function returning any of the above**: `fn input, context -> ... end`

  ### Using ReqLLM.Context (Recommended)

  ```elixir
  import ReqLLM.Context

  run prompt("openai:gpt-4o",
    prompt: fn input, _ctx ->
      ReqLLM.Context.new([
        system("You are an OCR expert"),
        user([
          ReqLLM.Message.ContentPart.text("Extract text from this image"),
          ReqLLM.Message.ContentPart.image_url(input.arguments.image_url)
        ])
      ])
    end
  )
  ```

  ### Legacy Map Format

  For convenience, loose maps with role/content keys are also supported:

  ```elixir
  [
    %{role: "system", content: "You are an OCR expert"},
    %{role: "user", content: "Extract text: <%= @input.arguments.text %>"}
  ]
  ```

  The default prompt template is:

  ```elixir
  #{inspect(@prompt_template, pretty: true)}
  ```
  """
  use Ash.Resource.Actions.Implementation

  def run(input, opts, context) do
    model = resolve_model_spec(opts[:model], input, context)
    schema = build_json_schema(input)
    initial_context = build_context(input, opts, context)

    req_llm_module = Keyword.get(opts, :req_llm, ReqLLM)
    req_llm_opts = Keyword.get(opts, :req_llm_opts, [])

    with {:ok, final_context} <-
           maybe_run_tools(
             initial_context,
             input,
             context,
             model,
             req_llm_module,
             opts
           ),
         {:ok, generated} <-
           req_llm_module.generate_object(model, final_context, schema, req_llm_opts) do
      case generated do
        %{object: result} ->
          cast_result(result, input.action)

        result when is_map(result) ->
          cast_result(result, input.action)
      end
    else
      {:error, error} ->
        {:error, error}
    end
  end

  defp resolve_model_spec(model, input, context) when is_function(model, 2) do
    resolve_model_spec(model.(input, context), input, context)
  end

  defp resolve_model_spec(model, input, context) when is_function(model, 1) do
    resolve_model_spec(model.(input), input, context)
  end

  defp resolve_model_spec(model, _input, _context) when is_function(model, 0) do
    model.()
  end

  defp resolve_model_spec(model, _input, _context), do: model

  defp maybe_run_tools(reqllm_context, input, context, model, req_llm_module, opts) do
    case Keyword.get(opts, :tools, false) do
      false ->
        {:ok, reqllm_context}

      nil ->
        {:ok, reqllm_context}

      tool_selection ->
        case prompt_loop_opts(
               tool_selection,
               input,
               context,
               model,
               req_llm_module,
               opts
             ) do
          {:ok, loop_opts} ->
            case AshAi.ToolLoop.run(reqllm_context.messages, loop_opts) do
              {:ok, %AshAi.ToolLoop.Result{messages: messages}} ->
                {:ok, ReqLLM.Context.new(messages)}

              {:error, reason} ->
                if Keyword.get(opts, :verbose?, false) do
                  Logger.debug(fn ->
                    "AshAi.Actions.Prompt tool loop failed: #{inspect(reason)}"
                  end)
                end

                {:error,
                 Ash.Error.Unknown.UnknownError.exception(
                   error: "Tool loop failed in prompt action: #{inspect(reason)}"
                 )}
            end

          {:error, error} ->
            {:error, error}
        end
    end
  end

  defp prompt_loop_opts(tool_selection, input, context, model, req_llm_module, opts) do
    domain = Ash.Resource.Info.domain(input.resource)
    actor = Map.get(context, :actor)
    tenant = Map.get(context, :tenant)
    source_context = Map.get(context, :source_context) || %{}

    base_opts =
      [
        model: model,
        req_llm: req_llm_module,
        max_iterations: Keyword.get(opts, :max_iterations, :infinity),
        actor: actor,
        tenant: tenant,
        context: source_context,
        strict: Keyword.get(opts, :strict, true),
        tools: tool_selection
      ]
      |> maybe_put_option(:on_tool_start, on_tool_start(opts))
      |> maybe_put_option(:on_tool_end, on_tool_end(opts))

    cond do
      Keyword.has_key?(opts, :actions) ->
        {:ok, Keyword.put(base_opts, :actions, Keyword.fetch!(opts, :actions))}

      Keyword.has_key?(opts, :otp_app) ->
        {:ok, Keyword.put(base_opts, :otp_app, Keyword.fetch!(opts, :otp_app))}

      domain ->
        domain_actions =
          domain
          |> AshAi.Info.tools()
          |> Enum.group_by(& &1.resource, & &1.action)
          |> Map.to_list()

        {:ok, Keyword.put(base_opts, :actions, domain_actions)}

      true ->
        {:error,
         Ash.Error.Unknown.UnknownError.exception(
           error: """
           Prompt action tool use requires either:
           - `otp_app: :your_app`, or
           - explicit `actions: [{Resource, [:action]}]`, or
           - a resource with a resolvable Ash domain.
           """
         )}
    end
  end

  defp build_json_schema(input) do
    if input.action.returns do
      inner_schema = return_inner_schema(input.action)

      result_schema =
        if input.action.allow_nil? do
          %{"anyOf" => [%{"type" => "null"}, inner_schema]}
        else
          inner_schema
        end

      %{
        "type" => "object",
        "properties" => %{
          "result" => result_schema
        },
        "required" => ["result"],
        "additionalProperties" => false
      }
    else
      %{
        "type" => "object",
        "properties" => %{},
        "additionalProperties" => false
      }
    end
  end

  defp return_inner_schema(%{returns: :map} = action) do
    if unconstrained_map_return?(action.constraints) do
      %{"type" => "object"}
    else
      AshAi.OpenApi.resource_write_attribute_type(
        %{name: :result, type: action.returns, constraints: action.constraints},
        nil,
        :create
      )
    end
  end

  defp return_inner_schema(action) do
    AshAi.OpenApi.resource_write_attribute_type(
      %{name: :result, type: action.returns, constraints: action.constraints},
      nil,
      :create
    )
  end

  defp unconstrained_map_return?(constraints) when is_list(constraints) do
    Keyword.get(constraints, :fields) in [nil, []]
  end

  defp unconstrained_map_return?(constraints) when is_map(constraints) do
    Map.get(constraints, :fields) in [nil, []]
  end

  defp unconstrained_map_return?(_), do: true

  defp on_tool_start(opts) do
    compose_callbacks(
      verbose_tool_start_callback(Keyword.get(opts, :verbose?, false)),
      opts[:on_tool_start]
    )
  end

  defp on_tool_end(opts) do
    compose_callbacks(
      verbose_tool_end_callback(Keyword.get(opts, :verbose?, false)),
      opts[:on_tool_end]
    )
  end

  defp compose_callbacks(nil, nil), do: nil
  defp compose_callbacks(callback, nil) when is_function(callback, 1), do: callback
  defp compose_callbacks(nil, callback) when is_function(callback, 1), do: callback

  defp compose_callbacks(first, second) when is_function(first, 1) and is_function(second, 1) do
    fn event ->
      first.(event)
      second.(event)
    end
  end

  defp verbose_tool_start_callback(false), do: nil

  defp verbose_tool_start_callback(true) do
    fn event ->
      Logger.debug(fn ->
        "AshAi.Actions.Prompt tool start tool=#{event.tool_name} action=#{event.action} arguments=#{inspect(event.arguments)}"
      end)
    end
  end

  defp verbose_tool_end_callback(false), do: nil

  defp verbose_tool_end_callback(true) do
    fn event ->
      Logger.debug(fn ->
        "AshAi.Actions.Prompt tool end tool=#{event.tool_name} result=#{inspect(event.result)}"
      end)
    end
  end

  defp maybe_put_option(opts, _key, nil), do: opts
  defp maybe_put_option(opts, key, value), do: Keyword.put(opts, key, value)

  defp cast_result(result, action) do
    value = unwrap_result(result)

    with {:ok, value} <-
           Ash.Type.cast_input(
             action.returns,
             value,
             action.constraints
           ),
         {:ok, value} <-
           Ash.Type.apply_constraints(
             action.returns,
             value,
             action.constraints
           ) do
      {:ok, value}
    else
      {:error, error} ->
        {:error, "Failed to cast LLM response: #{inspect(error)}. Response: #{inspect(result)}"}
    end
  end

  defp unwrap_result(%{"result" => value}), do: value
  defp unwrap_result(%{result: value}), do: value
  defp unwrap_result(value), do: value

  # sobelow_skip ["RCE.EEx"]
  defp build_context(input, opts, context) do
    prompt = Keyword.get(opts, :prompt, @prompt_template)

    prompt_value =
      case prompt do
        func when is_function(func, 2) ->
          func.(input, context)

        other ->
          other
      end

    normalize_to_context(prompt_value, input, context)
  end

  # sobelow_skip ["RCE.EEx"]
  defp normalize_to_context(prompt, input, context) do
    case prompt do
      # Already a ReqLLM.Context - pass through
      %ReqLLM.Context{} = ctx ->
        ctx

      # String template - evaluate and create system + user messages
      prompt when is_binary(prompt) ->
        system_prompt = EEx.eval_string(prompt, assigns: [input: input, context: context])

        ReqLLM.Context.new([
          ReqLLM.Context.system(system_prompt),
          ReqLLM.Context.user("Perform the action")
        ])

      # {system, user} tuple - evaluate both templates
      {system, user} when is_binary(system) and is_binary(user) ->
        system_prompt = EEx.eval_string(system, assigns: [input: input, context: context])
        user_message = EEx.eval_string(user, assigns: [input: input, context: context])

        ReqLLM.Context.new([
          ReqLLM.Context.system(system_prompt),
          ReqLLM.Context.user(user_message)
        ])

      # List of messages - process EEx templates in string content, then normalize
      messages when is_list(messages) ->
        processed = process_message_templates(messages, input, context)
        ReqLLM.Context.normalize!(processed, convert_loose: true)
    end
  end

  # sobelow_skip ["RCE.EEx"]
  defp process_message_templates(messages, input, context) do
    Enum.map(messages, fn msg ->
      case msg do
        # ReqLLM.Message struct - process content if it's a string
        %ReqLLM.Message{content: content} = message when is_binary(content) ->
          processed = EEx.eval_string(content, assigns: [input: input, context: context])
          %{message | content: processed}

        %ReqLLM.Message{} = message ->
          message

        # Loose map with string keys
        %{"content" => content} = map when is_binary(content) ->
          processed = EEx.eval_string(content, assigns: [input: input, context: context])
          Map.put(map, "content", processed)

        # Loose map with atom keys
        %{content: content} = map when is_binary(content) ->
          processed = EEx.eval_string(content, assigns: [input: input, context: context])
          Map.put(map, :content, processed)

        # Pass through anything else (ReqLLM.Context.normalize will handle it)
        other ->
          other
      end
    end)
  end
end
