# Credentials

ActiveAI ships a database-backed credential store for apps that need to manage API keys per user, account, or team — rather than globally via ENV. Keys are encrypted at rest using Rails' built-in encrypted attribute support.

---

## When to use this

Use the credential store when:
- Different accounts need different API keys (multi-tenant SaaS)
- Users supply their own provider keys
- You want a UI for managing keys without touching environment variables

Use ENV or Rails credentials instead when:
- All API calls go through a single set of keys
- Key management is ops-level, not user-level

---

## Setup

Run the generator to create the `ai_credentials` migration:

```bash
rails generate active_ai:credentials
rails db:migrate
```

---

## `ActiveAI::Credential` model

The `ai_credentials` table stores one key per `(owner, category, name)` combination:

| Column | Type | Description |
|---|---|---|
| `owner_type` | string | Polymorphic owner type (e.g., `"Account"`) |
| `owner_id` | integer | Polymorphic owner ID |
| `category` | string | `"provider"` or `"tool"` |
| `name` | string | Provider or tool name (e.g., `"anthropic"`, `"firecrawl"`) |
| `api_key` | encrypted string | The API key, encrypted at rest |

**Validations:**
- `category` must be `"provider"` or `"tool"`
- `name` must be a registered provider or tool name
- `(name, owner, category)` must be unique

**Scopes:**
```ruby
Credential.providers   # WHERE category = 'provider'
Credential.tools       # WHERE category = 'tool'
```

---

## `HasCredentials` mixin

Include on any model to add credential ownership:

```ruby
class Account < ApplicationRecord
  include ActiveAI::HasCredentials
end

class Setting < ApplicationRecord
  include ActiveAI::HasCredentials

  def self.instance
    find_or_create_by(id: 1)
  end
end
```

### Methods added by `HasCredentials`

**`api_key_for(name, category: "provider")`**

Returns the decrypted API key for a given provider or tool:

```ruby
account.api_key_for(:anthropic)              # => "sk-ant-..."
account.api_key_for(:firecrawl, category: "tool")  # => "fc-..."
```

**`configured_providers`**

Returns an array of provider names for which this owner has a stored key:

```ruby
account.configured_providers   # => ["anthropic", "openai"]
```

**`configured_tools`**

Returns an array of tool names for which this owner has a stored key:

```ruby
account.configured_tools   # => ["firecrawl"]
```

**`model_options_for(provider)`**

Returns the live model list for a provider, falling back to the provider's built-in defaults if the API call fails:

```ruby
account.model_options_for(:anthropic)
# => ["claude-sonnet-4-6", "claude-haiku-4-5-20251001", "claude-opus-4-8"]
```

---

## Wiring credentials into the resolver

Point `api_key_resolver` at the credential store:

```ruby
# config/initializers/active_ai.rb
ActiveAI.configure do |config|
  config.api_key_resolver = ->(provider) { Setting.instance.api_key_for(provider) }
end
```

For per-account keys:

```ruby
config.api_key_resolver = ->(provider) { Current.account&.api_key_for(provider) }
```

When `Current.account` is nil (background jobs, unauthenticated requests), the resolver returns nil and the chain falls through to Rails credentials → ENV.

---

## Registered provider and tool names

By default, the following names are valid for the `name` column:

**Providers:** `anthropic`, `openai`, `xai`

**Tools:** `firecrawl`, `brave`, `tavily`

To register a custom provider or tool name:

```ruby
# After registering the provider:
ActiveAI.register_provider("gemini", "GeminiProvider")

# The credential model picks up new providers automatically via:
# ActiveAI::Credential.provider_names => ["anthropic", "openai", "xai", "gemini"]
```

Similarly for tool names after registering a custom search adapter.
