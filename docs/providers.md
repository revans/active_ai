# Providers

A provider wraps one LLM API. Providers handle request formatting, streaming, tool call extraction, and usage reporting. The agent declares which provider to use; the provider does the wire-level work.

**For built-in providers (Anthropic, OpenAI, xAI):** you declare `provider :anthropic` on the agent. That's it — the library handles everything else.

**For custom providers:** you implement the `Provider::Base` interface (see below) and call `ActiveAI.register_provider`. The library handles routing, key resolution, and the agentic loop.

---

## Built-in providers

### Anthropic

```ruby
provider :anthropic
model "claude-sonnet-4-6", max_tokens: 8096
```

Requires `gem "anthropic"` in your Gemfile.

API key resolution order: `api_key_resolver` → `Rails.application.credentials.active_ai.anthropic_api_key` → `ENV["ANTHROPIC_API_KEY"]`

**Available models:** `claude-sonnet-4-6`, `claude-haiku-4-5-20251001`, `claude-opus-4-8` (plus any new models returned by the `/v1/models` endpoint).

**Prompt caching:** Anthropic supports cache control on system blocks, giving latency and cost reductions for content that doesn't change between calls. ActiveAI applies caching automatically based on your `cache` declarations:

```ruby
cache :system,       ttl: "1h"   # base system prompt cached for 1 hour
cache :source_files, ttl: "1h"   # source file content cached for 1 hour
cache :context,      ttl: "5m"   # document context cached for 5 minutes
```

Each skill also gets its own cache block, so individual skills can be cached independently.

**Usage fields returned:** `input_tokens`, `output_tokens`, `cache_creation_tokens`, `cache_read_tokens`, `stop_reason`, `provider_request_id`.

---

### OpenAI

```ruby
provider :openai
model "gpt-4.1"
```

Requires `gem "ruby-openai"` in your Gemfile.

API key resolution: `api_key_resolver` → `Rails.application.credentials.active_ai.openai_api_key` → `ENV["OPENAI_API_KEY"]`

**Available models:** `gpt-4.1`, `gpt-4.1-mini`, `gpt-4.1-nano`, `gpt-4o`, `gpt-4o-mini`, `o4-mini`, `o3-mini`, `o3` (plus live models from the API).

**Caching:** OpenAI does not support per-block caching. The system prompt, skills, and source files are combined into a single system message. OpenAI's own automatic prompt caching applies to repeated prefixes, but this is transparent to the application.

**Usage fields returned:** `input_tokens`, `output_tokens`, `cache_read_tokens` (from `prompt_tokens_details`), `stop_reason`.

---

### xAI (Grok)

```ruby
provider :xai
model "grok-3"
```

Requires `gem "ruby-openai"` in your Gemfile. xAI inherits from the OpenAI provider and overrides only the API base URL and model list.

API key resolution: `api_key_resolver` → `Rails.application.credentials.active_ai.xai_api_key` → `ENV["XAI_API_KEY"]`

**Available models:** `grok-3`, `grok-3-mini`.

---

## Provider model defaults

`ApplicationAgent` ships with defaults so agents that declare a provider but no model get the right fallback automatically:

```ruby
self.provider_model_defaults = {
  anthropic: "claude-sonnet-4-6",
  openai:    "gpt-4.1",
  xai:       "grok-3"
}
```

Override `provider_model_defaults` on your `ApplicationAgent` to change these.

---

## Model list caching

Each provider caches its live model list for 24 hours (using `ActiveSupport::Cache`). If the API call fails, it falls back to a hardcoded `model_defaults` array. You can call `ProviderClass.models` to get the current list:

```ruby
ActiveAI::Provider::Anthropic.models   # => ["claude-sonnet-4-6", "claude-haiku-4-5-20251001", ...]
ActiveAI::Provider::OpenAI.models      # => ["gpt-4.1", "gpt-4.1-mini", ...]
```

---

## Custom providers

Create a class that inherits from `ActiveAI::Provider::Base`:

```ruby
class GeminiProvider < ActiveAI::Provider::Base
  MODEL_DEFAULTS = %w[gemini-2.0-flash gemini-1.5-pro].freeze

  def self.model_defaults
    MODEL_DEFAULTS
  end

  def self.fetch_models(api_key:)
    # Hit the provider's models endpoint and return an array of model ID strings.
    # Return nil on failure — ActiveAI falls back to model_defaults.
    response = Net::HTTP.get_response(URI("https://generativelanguage.googleapis.com/v1beta/models"),
                                      { "Authorization" => "Bearer #{api_key}" })
    JSON.parse(response.body)["models"].map { |m| m["name"] }
  rescue
    nil
  end

  def stream(params, &block)
    # params contains: model, max_tokens, system, messages, tools, cacheable, skills, source_files
    # Yield each text chunk as a String.
    # After streaming completes, populate @last_tool_calls and @last_usage.
    # See lib/active_ai/provider/anthropic.rb for a full reference implementation.
  end
end
```

Register it in an initializer:

```ruby
ActiveAI.register_provider("gemini", "GeminiProvider")
```

After registration, `provider :gemini` works in any agent class.

### Provider interface (`ActiveAI::Provider::Base`)

| Method | Required? | Description |
|---|---|---|
| `stream(params, &block)` | Yes | Stream a response; yield text chunks as Strings |
| `model_defaults` | Yes (class) | Array of model ID strings (fallback when API unreachable) |
| `fetch_models(api_key:)` | No (class) | Hit provider's `/models` endpoint; return array or nil |
| `call(params)` | No | Blocking call; base implementation raises NotImplementedError |
| `last_tool_calls` | No | Tool calls extracted from the last response; base returns `[]` |
| `last_usage` | No | Token usage hash from the last call; base returns `nil` |
| `last_assistant_content` | No | Raw assistant content array from the last turn; base returns `[]` |
| `format_assistant_turn(content, tool_calls)` | No | Formats the assistant message to append to history before the tool result. **Must override if your provider uses a different wire format for tool calls.** Default is Anthropic format (content array). OpenAI requires `{ role: "assistant", content: nil, tool_calls: [...] }`. |
| `format_tool_result_messages(tool_results)` | No | Formats tool results as messages to append to history. **Must override if your provider expects a different structure.** Default bundles all results in one `role: "user"` message (Anthropic). OpenAI requires one `role: "tool"` message per result. |

`format_assistant_turn` and `format_tool_result_messages` are only called during the agentic loop (when the model returns tool calls). If your custom provider doesn't support tools, you can skip them. If it does, wrong formats here cause silent 400 errors from the provider API — override both to match your provider's wire format.
