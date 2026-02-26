# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.Info do
  @moduledoc "Introspection functions for the `AshAi` extension."
  use Spark.InfoGenerator, extension: AshAi, sections: [:tools, :vectorize, :mcp_resources]

  @doc """
  Returns only `%AshAi.McpUiResource{}` entities from the `:mcp_resources` section.

  Spark's auto-generated `mcp_resources/1` returns all entities in the section
  (both `mcp_resource` and `mcp_ui_resource`). This function filters to UI resources only.
  """
  @spec mcp_ui_resources(module | map) :: [AshAi.McpUiResource.t()]
  def mcp_ui_resources(dsl_or_extended) do
    dsl_or_extended
    |> mcp_resources()
    |> Enum.filter(&match?(%AshAi.McpUiResource{}, &1))
  end

  @doc """
  Returns only `%AshAi.McpResource{}` entities (action-based) from the `:mcp_resources` section.
  """
  @spec mcp_action_resources(module | map) :: [AshAi.McpResource.t()]
  def mcp_action_resources(dsl_or_extended) do
    dsl_or_extended
    |> mcp_resources()
    |> Enum.filter(&match?(%AshAi.McpResource{}, &1))
  end
end
