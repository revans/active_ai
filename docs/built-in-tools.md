# Built-in Tools

ActiveAI ships two tools that are available in any agent without generating custom code. Register them with `tools` at the class level.

| Library handles | You configure |
|---|---|
| `WebPageReader` — full SSRF protection, HTML stripping, size limit | Nothing — no key or config required |
| `WebSearch` — routing to search adapter, result formatting | `search_provider` and API key in `config/initializers/active_ai.rb` |
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
