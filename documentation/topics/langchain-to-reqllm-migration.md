# LangChain to ReqLLM Migration Guide

This guide covers migrating an `ash_ai` app from the old LangChain-based runtime to the ReqLLM-based runtime.

## What Changed

- LangChain runtime integration was removed.
- LLM access now goes through ReqLLM.
- Tool orchestration now goes through `AshAi.ToolLoop`.
- Prompt-backed actions (`prompt/2`) now use ReqLLM model specifications.
- Generated chat code (`mix ash_ai.gen.chat`) now uses ReqLLM.

## Migration Checklist

1. Update dependencies (`:langchain` out, `:req_llm` in).
2. Move provider keys to `config :req_llm`.
3. Replace LangChain model structs with ReqLLM model specs.
4. Replace removed AshAi APIs with ReqLLM-first APIs.
5. Re-run chat generator if you use generated chat code.
6. Run format/tests/checks.

## 1) Update Dependencies

In `mix.exs`:

- Remove LangChain dependency.
- Add ReqLLM dependency:

```elixir
{:req_llm, "~> 1.6"}
```

Then fetch and resolve:

```bash
mix deps.get
```

## 2) Update Runtime Configuration

Configure provider keys under `:req_llm` in `config/runtime.exs`.

```elixir
config :req_llm,
  openai_api_key: System.get_env("OPENAI_API_KEY"),
  anthropic_api_key: System.get_env("ANTHROPIC_API_KEY"),
  google_api_key: System.get_env("GOOGLE_API_KEY")
```

Use only the providers your app needs.

## 3) Update Model Specifications

`prompt/2` and tool loops now use ReqLLM model specs.

- Before (LangChain struct-based setup):

```elixir
LangChain.ChatModels.ChatOpenAI.new!(%{model: "gpt-4o"})
```

- After (ReqLLM model spec):

```elixir
"openai:gpt-4o"
```

Model strings follow `"provider:model-name"` and can be browsed at https://llmdb.xyz.

## 4) Replace Removed APIs

| Old | New |
| --- | --- |
| `AshAi.setup_ash_ai/2` | `AshAi.ToolLoop.run/2` or `AshAi.ToolLoop.stream/2` |
| `AshAi.functions/1` | `AshAi.list_tools/1` or `AshAi.build_tools_and_registry/1` |
| `AshAi.iex_chat/2` | `AshAi.iex_chat/1` |

## 5) Update Prompt-Backed Actions

The `prompt/2` macro remains, but model input uses ReqLLM model specs.

```elixir
run prompt("openai:gpt-4o",
  prompt: "Summarize: <%= @input.arguments.text %>",
  tools: true
)
```

Supported model forms:

- String model spec (`"provider:model"`)
- ReqLLM tuple model forms
- Function returning one of the above

## 6) Update Embeddings (If Used)

Use `AshAi.EmbeddingModels.ReqLLM` with explicit `model` and `dimensions`.

```elixir
vectorize do
  embedding_model {AshAi.EmbeddingModels.ReqLLM,
    model: "openai:text-embedding-3-small",
    dimensions: 1536
  }
end
```

## 7) Regenerate Chat Code (If Used)

If your app uses generated chat files, re-run:

```bash
mix ash_ai.gen.chat --live
```

or your existing generator flags. The generated code now uses ReqLLM and `AshAi.ToolLoop`.

## 8) Validate the Migration

Run:

```bash
mix format
mix test
mix check
```

Optional sanity check:

```bash
rg -n "LangChain|langchain" lib test config
```

## Common Issues

- Missing API key errors:
  Add the matching `:req_llm` key or environment variable for your selected provider.
- Provider schema compatibility:
  If a provider rejects strict tool schemas, set `strict: false` in tool loop or prompt tool options.
