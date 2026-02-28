<!--
SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs.contributors>

SPDX-License-Identifier: MIT
-->

# Google Gemini Configuration
Steps to configure The generated Chat Server to work with Gemini


## Configuration
In `config/runtime.ex` replace:

```elixir
config :req_llm, openai_api_key: System.fetch_env!("OPENAI_API_KEY")
```

With:

```elixir
config :req_llm,
  google_api_key: System.fetch_env!("GOOGLE_API_KEY")
```



## Chat Component

In
- `lib/your_app/chat/message/changes/respond.ex`
- `lib/your_app/chat/conversation/changes/generate_name.ex`


Replace:

```elixir
 model: "openai:gpt-4o"

```
With:

```elixir
 model: "google:gemini-2.5-pro"
```


## Embeddings

create `lib/your_app/google_ai_embedding_model.ex`

```elixir
defmodule YourApp.GoogleAiEmbeddingModel do
  use AshAi.EmbeddingModel

  @impl true
  def dimensions(_opts), do: 3072

  @impl true
  def generate(texts, _opts) do
    parts = Enum.map(texts, fn t -> %{text: t} end)
    api_key = System.fetch_env!("GEMINI_API_KEY")

    headers = [
      {"x-goog-api-key", "#{api_key}"},
      {"Content-Type", "application/json"}
    ]

    body = %{
      "content" => %{parts: parts},
      "model" => "models/gemini-embedding-001"
    }

    response =
      Req.post!(
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-embedding-001:embedContent",
        json: body,
        headers: headers
      )

    case response.status do
      200 ->
        {:ok, [response.body["embedding"]["values"]]}

      _status ->
        {:error, response.body}
    end
  end
end
```

and in your `vectorize` block change:

```elixir
embedding_model YourApp.OpenAiEmbeddingModel
```

with:

```elixir
embedding_model YourApp.GoogleAiEmbeddingModel
```
