# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshAi.Gen.ChatTest do
  use ExUnit.Case
  import Igniter.Test

  test "--live flag doesnt explode" do
    igniter =
      phx_test_project()
      |> Igniter.compose_task("ash_ai.gen.chat", [
        "--user",
        "MyApp.Accounts.User",
        "--live",
        "--extend",
        "ets"
      ])
      |> apply_igniter!()

    assert Igniter.Project.Module.module_exists(igniter, Test.Chat.Conversation)
           |> elem(0)

    assert Igniter.Project.Module.module_exists(igniter, Test.Chat.Message)
           |> elem(0)

    assert Igniter.Project.Module.module_exists(igniter, TestWeb.ChatLive)
           |> elem(0)
  end

  test "--live with --domain uses domain suffix for LiveView module name" do
    igniter =
      phx_test_project()
      |> Igniter.compose_task("ash_ai.gen.chat", [
        "--user",
        "MyApp.Accounts.User",
        "--live",
        "--domain",
        "Test.SupportChat",
        "--extend",
        "ets"
      ])
      |> apply_igniter!()

    assert Igniter.Project.Module.module_exists(igniter, TestWeb.SupportChatLive)
           |> elem(0)
  end

  test "--live-component generates component with name derived from --domain" do
    igniter =
      phx_test_project()
      |> Igniter.compose_task("ash_ai.gen.chat", [
        "--user",
        "MyApp.Accounts.User",
        "--domain",
        "Test.SupportChat",
        "--live-component",
        "--extend",
        "ets"
      ])
      |> apply_igniter!()

    assert Igniter.Project.Module.module_exists(igniter, TestWeb.SupportChatComponent)
           |> elem(0)
  end

  test "--route option sets the live route path in router.ex" do
    phx_test_project()
    |> Igniter.Project.Module.find_and_update_module!(TestWeb.Router, fn zipper ->
      {:ok,
       Igniter.Code.Common.add_code(zipper, """
       ash_authentication_live_session :authenticated do
       end
       """)}
    end)
    |> apply_igniter!()
    |> Igniter.compose_task("ash_ai.gen.chat", [
      "--user",
      "MyApp.Accounts.User",
      "--live",
      "--route",
      "/support/chat",
      "--provider",
      "openai",
      "--extend",
      "ets"
    ])
    |> assert_has_patch("lib/test_web/router.ex", """
    +|live "/support/chat", ChatLive
    +|live "/support/chat/:conversation_id", ChatLive
    """)
    |> assert_has_patch("config/runtime.exs", """
    + |config :langchain, openai_key: fn -> System.fetch_env!("OPENAI_API_KEY") end
    """)
    |> apply_igniter!()
  end
end
