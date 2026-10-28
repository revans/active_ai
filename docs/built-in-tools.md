# Built-in Tools

ActiveAI ships three tools that are available in any agent without generating custom code. Register them with `tools` at the class level.

| Library handles | You configure |
|---|---|
| `WebPageReader` — full SSRF protection, HTML stripping, size limit | Nothing — no key or config required |
| `WebSearch` — routing to search adapter, result formatting | `search_provider` and API key in `config/initializers/active_ai.rb` |
| `RecordQuery` — read-only ActiveRecord queries, row limit, write prevention | `ActiveAI::Readable` declarations on your models, and the `roots:` relation the user may reach |
| `SearchAdapter` base class for custom backends | Custom adapter class + `SearchAdapter.register` if using a non-built-in provider |

---

## WebPageReader

Fetches a URL, strips HTML/scripts/styles, and returns up to 8,000 characters of readable text. Uses Ruby stdlib only — no API key required.

```ruby
class ResearchAgent < ApplicationAgent
  tools ActiveAI::Tools::WebPageReader
end
```

The model can now call `read_webpage(url: "https://...")` mid-conversation.

### Security

`WebPageReader` applies multiple layers of protection against SSRF (Server-Side Request Forgery) — the attack where a malicious input URL causes your server to make requests to internal services:

- **Scheme validation** — Only `http` and `https` are allowed. `file://`, `ftp://`, and similar are rejected.
- **Port validation** — Only ports 80 and 443 are accepted.
- **DNS resolution and IP validation** — All resolved IP addresses are checked against blocked ranges before connecting:
  - Loopback: `127.0.0.0/8`, `::1/128`
  - Private: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `fc00::/7`
  - Link-local / cloud metadata: `169.254.0.0/16`, `fe80::/10` (blocks AWS/GCP metadata endpoints)
  - CGNAT: `100.64.0.0/10`
  - Reserved: `0.0.0.0/8`, `224.0.0.0/4`, `240.0.0.0/4`, `ff00::/8`
- **Direct IP connection** — After validating the resolved IP, the connection is made directly to that IP, preventing DNS rebinding attacks.
- **Response size limit** — Rejects responses over 2 MB via `Content-Length` header check before reading the body.
- **Redirect handling** — Follows up to 5 redirects, validating the target URL at each hop.

---

## WebSearch

Searches the web and returns formatted results. Requires a search provider to be configured.

```ruby
class ResearchAgent < ApplicationAgent
  tools ActiveAI::Tools::WebSearch
end
```

The model can now call `web_search(query: "...")` mid-conversation.

### Configuring a search provider

Set `search_provider` and the corresponding API key in your initializer:

```ruby
ActiveAI.configure do |config|
  config.search_provider = :firecrawl
  config.search_api_key  = ENV["FIRECRAWL_API_KEY"]
end
```

If `search_provider` is not configured and the model calls `web_search`, the tool raises `ActiveAI::Tools::NotConfiguredError`.

### Supported providers

| Provider | Symbol | ENV variable | Notes |
|---|---|---|---|
| Firecrawl | `:firecrawl` | `FIRECRAWL_API_KEY` | Full-page content extraction |
| Brave Search | `:brave` | `BRAVE_API_KEY` | Standard web index |
| Tavily | `:tavily` | `TAVILY_API_KEY` | AI-optimized results |

All three return up to 5 results formatted as a `Title / URL / Content` block for the model to read.

### Using a different key per environment

The `search_api_key` config attribute takes precedence over ENV. For environment-specific keys:

```ruby
config.search_api_key = Rails.application.credentials.dig(:firecrawl, :api_key)
```

---

## SearchAdapter (custom search providers)

`WebSearch` delegates to a `SearchAdapter`. You can register a custom adapter if you need a different search backend:

```ruby
class InternalSearchAdapter < ActiveAI::Tools::SearchAdapter::Base
  def search(query)
    results = InternalSearch.query(query, limit: 5)
    format_results(results.map { |r| { title: r.title, url: r.url, body: r.excerpt } })
  end
end

ActiveAI.configure do |config|
  config.search_provider = :internal
end

# Register the adapter — add to config/initializers/active_ai.rb
ActiveAI::Tools::SearchAdapter.register(:internal, InternalSearchAdapter)
```

`format_results` is provided by `SearchAdapter::Base` and formats an array of `{ title:, url:, body: }` hashes into a readable string. Override the entire method if you need a different output format.

---

## RecordQuery

Gives the model read-only access to your database through ActiveRecord models — never SQL. The model reads only what your models declare, and only under records your app says the current user may reach.

### Declare what is readable

Nothing is readable until a model includes `ActiveAI::Readable` and declares it:

```ruby
class Account < ApplicationRecord
  include ActiveAI::Readable
  ai_readable associations: [:orders,
                              { audit_entries: { if: ->(account, user) { user.admin_of?(account) } } }]
end

class Order < ApplicationRecord
  include ActiveAI::Readable

  scope :shipped, -> { where(status: "shipped") }
  scope :since,   ->(date) { where(placed_on: Date.parse(date)..) }

  ai_readable scopes:     { shipped: "Orders that have shipped",
                            since:   "Orders placed on or after a date (YYYY-MM-DD)" },
              attributes: %i[number status placed_at total]
end
```

| Option | Means |
|---|---|
| `associations:` | `has_many` associations the model may walk from this record. A hash entry takes `if: ->(record, context)`, called with the tool's `context:`. |
| `scopes:` | Scopes, or class methods returning a relation of this model, the model may apply. A hash gives each a description the model sees. |
| `attributes:` | Attributes (or reader methods) returned for each record. Nothing else is returned. |

### Register it with the user's roots

The tool needs the current user, so register it per instance:

```ruby
class ReportingAgent < ApplicationAgent
  def initialize(user:, **kwargs)
    @user = user
    super(**kwargs)
  end

  def instance_tools
    [ActiveAI::Tools::RecordQuery.new(roots: @user.accounts, context: @user)]
  end
end
```

Pass the user in when you build the agent rather than reading `Current` inside it: workflows run parallel steps on new threads, where `Current` is empty.

The model calls `query_records(root_id:)` to see what it can read under a root, then `query_records(root_id:, association:, scopes: [{ name:, args: [] }], limit:)`.

### What it guarantees

- **The root is yours to bound.** The root id is looked up only within `roots:`; one outside it is "not found", whether or not it exists.
- **Results stay under the root.** After the model's scopes are applied, the association is re-applied as `WHERE id IN (...)`, so even a declared scope that calls `unscoped` cannot return another root's records.
- **No writes.** Everything runs inside `ActiveRecord::Base.while_preventing_writes`; on PostgreSQL, also inside a `READ ONLY` transaction with a statement timeout (5 s by default, `statement_timeout_ms:`). The PostgreSQL transaction is skipped when the call is already inside a transaction.
- **Bounded output.** At most 50 rows by default and never more than `max_limit:` (200). The result carries `returned`, `truncated` and `total` — the exact number of matching records — so "how many" stays right past the limit. The count runs only when the rows were cut short.

Errors the model can fix (an unknown scope, wrong arguments, a timeout) come back as `{ "error": "..." }`. A declaration that cannot work — an association that is not `has_many`, a target model without `ActiveAI::Readable`, a declared method that does not return a relation of its model, a composite primary key — raises `ActiveAI::ConfigurationError`.
