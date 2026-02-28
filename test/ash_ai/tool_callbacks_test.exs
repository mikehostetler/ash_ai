# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.ToolCallbacksTest do
  use ExUnit.Case, async: true

  alias __MODULE__.{TestDomain, TestResource}

  defmodule TestResource do
    use Ash.Resource, domain: TestDomain, data_layer: Ash.DataLayer.Ets

    attributes do
      uuid_v7_primary_key(:id, writable?: true)
      attribute :name, :string, public?: true, allow_nil?: false
      attribute :status, :string, public?: true
    end

    actions do
      defaults([:read, :create, :update, :destroy])
      default_accept([:id, :name, :status])

      action :custom_action, :string do
        argument :message, :string, allow_nil?: false

        run(fn input, _context ->
          {:ok, "Processed: #{input.arguments.message}"}
        end)
      end
    end
  end

  defmodule TestDomain do
    use Ash.Domain, extensions: [AshAi]

    resources do
      resource TestResource
    end

    tools do
      tool :read_test_resources, TestResource, :read
      tool :create_test_resource, TestResource, :create
      tool :update_test_resource, TestResource, :update
      tool :destroy_test_resource, TestResource, :destroy
      tool :custom_test_action, TestResource, :custom_action
    end
  end

  test "on_tool_start callback receives expected event" do
    test_pid = self()
    {_tools, registry} = AshAi.build_tools_and_registry(actions: [{TestResource, [:read]}])

    ctx = %{
      actor: %{id: "user_123"},
      tenant: "tenant_456",
      context: %{},
      tool_callbacks: %{
        on_tool_start: fn event -> send(test_pid, {:tool_start, event}) end
      }
    }

    {:ok, _json, _raw} = registry["read_test_resources"].(%{"limit" => 10}, ctx)

    assert_receive {:tool_start, %AshAi.ToolStartEvent{} = event}
    assert event.tool_name == "read_test_resources"
    assert event.action == :read
    assert event.resource == TestResource
    assert event.arguments == %{"limit" => 10}
    assert event.actor == %{id: "user_123"}
    assert event.tenant == "tenant_456"
  end

  test "on_tool_end callback receives expected event" do
    test_pid = self()
    {_tools, registry} = AshAi.build_tools_and_registry(actions: [{TestResource, [:read]}])

    ctx = %{
      actor: nil,
      tenant: nil,
      context: %{},
      tool_callbacks: %{
        on_tool_end: fn event -> send(test_pid, {:tool_end, event}) end
      }
    }

    {:ok, _json, _raw} = registry["read_test_resources"].(%{}, ctx)

    assert_receive {:tool_end, %AshAi.ToolEndEvent{} = event}
    assert event.tool_name == "read_test_resources"
    assert {:ok, _json, _raw} = event.result
  end

  test "callbacks are called in order" do
    test_pid = self()
    {_tools, registry} = AshAi.build_tools_and_registry(actions: [{TestResource, [:read]}])

    ctx = %{
      actor: nil,
      tenant: nil,
      context: %{},
      tool_callbacks: %{
        on_tool_start: fn event ->
          send(test_pid, {:tool_start, event, System.monotonic_time()})
        end,
        on_tool_end: fn event ->
          send(test_pid, {:tool_end, event, System.monotonic_time()})
        end
      }
    }

    {:ok, _json, _raw} = registry["read_test_resources"].(%{}, ctx)

    assert_receive {:tool_start, %AshAi.ToolStartEvent{} = start_event, start_time}
    assert_receive {:tool_end, %AshAi.ToolEndEvent{} = end_event, end_time}

    assert start_event.tool_name == end_event.tool_name
    assert start_time < end_time
  end

  test "callbacks work for custom actions" do
    test_pid = self()

    {_tools, registry} =
      AshAi.build_tools_and_registry(actions: [{TestResource, [:custom_action]}])

    ctx = %{
      actor: nil,
      tenant: nil,
      context: %{},
      tool_callbacks: %{
        on_tool_start: fn event -> send(test_pid, {:tool_start, event.tool_name}) end,
        on_tool_end: fn event -> send(test_pid, {:tool_end, event.tool_name, event.result}) end
      }
    }

    {:ok, json, _raw} =
      registry["custom_test_action"].(%{"input" => %{"message" => "Hello"}}, ctx)

    assert json == "\"Processed: Hello\""

    assert_receive {:tool_start, "custom_test_action"}

    assert_receive {:tool_end, "custom_test_action",
                    {:ok, "\"Processed: Hello\"", "Processed: Hello"}}
  end
end
