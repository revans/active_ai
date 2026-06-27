# Configuration

ActiveAI is configured in two places: `config/ai.yml` for static per-environment defaults, and `config/initializers/active_ai.rb` for runtime configuration (API keys, search provider).

---

## config/ai.yml

Works exactly like `config/database.yml` — one block of defaults per environment, all inheriting from a `default` anchor:

```yaml
default: &default
  provider: anthropic
  model: claude-sonnet-4-6
  max_tokens: 8096

development:
  <<: *default

test:
  <<: *default
  model: claude-haiku-4-5-20251001   # cheaper model for tests

production:
  <<: *default
```

**Keys:**

| Key | Type | Description |
|---|---|---|
| `provider` | string | Default provider: `anthropic`, `openai`, `xai`, or a custom name |
| `model` | string | Default model name for the provider |
| `max_tokens` | integer | Default max output tokens (default: 8096) |

These are the lowest-priority defaults. Any class-level `provider`, `model`, or `max_tokens` declaration overrides them. Runtime kwargs on `new(provider:, model:)` override those.

---

## ActiveAI.configure

Set in `config/initializers/active_ai.rb`. This is where you wire in your API key source and any optional features:

```ruby
ActiveAI.configure do |config|
  # Where to find API keys. Return nil to fall through to credentials/ENV.
  config.api_key_resolver = ->(provider) { Setting.instance.api_key_for(provider) }

  # Required only if you use ActiveAI::Tools::WebSearch
  config.search_provider = :firecrawl   # :firecrawl, :brave, or :tavily
  config.search_api_key  = ENV["FIRECRAWL_API_KEY"]
end
```

**Config attributes:**

| Attribute | Type | Description |
|---|---|---|
| `api_key_resolver` | callable or nil | Lambda `(provider_name) -> String \| nil`; called first in the key chain |
| `search_provider` | symbol or nil | `:firecrawl`, `:brave`, or `:tavily` |
| `search_api_key` | string or nil | Explicit key for the search provider; falls back to ENV if nil |

---

## API key resolution chain

For any provider, ActiveAI tries three sources in order and stops at the first non-blank result:

1. **`api_key_resolver`** — your lambda (database, secrets manager, or any custom logic)
2. **Rails credentials** — `Rails.application.credentials.active_ai.anthropic_api_key` (and similarly for other providers)
3. **ENV** — `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `XAI_API_KEY`

If the resolver returns `nil`, the chain moves to the next source automatically. This means the same initializer works for both single-tenant apps (resolver reads a singleton) and multi-tenant apps (resolver reads `Current.account`), with ENV as the universal fallback.

### Per-account API keys

```ruby
# config/initializers/active_ai.rb
ActiveAI.configure do |config|
  config.api_key_resolver = ->(provider) { Current.account&.api_key_for(provider) }
end
```

`Current.account` returning `nil` (background jobs, unauthenticated requests) causes the resolver to return `nil`, which falls through to credentials → ENV automatically.

---

## Accessing config at runtime

```ruby
ActiveAI.config.provider    # => :anthropic
ActiveAI.config.model       # => "claude-sonnet-4-6"
ActiveAI.config.max_tokens  # => 8096

ActiveAI.config.api_key_for(:anthropic)  # runs the full resolution chain
```

`api_key_for` is the same resolution chain the providers use internally — you can call it in tests or custom providers to verify key availability.

---

## Missing API key behavior

Each provider validates the API key at first use (when the HTTP client is first initialized — on the first `stream` or `complete` call). If the key is blank after the full resolution chain, it raises `ActiveAI::ConfigurationError` immediately with a message explaining which environment variable, credentials key, or initializer to set:

```
ActiveAI::ConfigurationError: No API key configured for :anthropic — set ANTHROPIC_API_KEY in ENV,
add it to Rails credentials under active_ai.anthropic_api_key, or register an api_key_resolver
in config/initializers/active_ai.rb
```

This means a missing key surfaces as a clear configuration error, not a cryptic 401 from the provider API.

---

## Model priority order

When resolving which model to use for a given agent call, ActiveAI checks in this order and uses the first non-nil value:

1. Runtime kwarg: `WritingAgent.new(model: "gpt-4.1-mini")`
2. Class declaration: `model "claude-sonnet-4-6"` on the agent class
3. `provider_model_defaults` on `ApplicationAgent` (maps provider → model)
4. `config/ai.yml` default model for the current environment
