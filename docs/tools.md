# Tools

Tools are executable functions the model can invoke mid-conversation. The model decides when to call a tool and what arguments to pass — ActiveAI executes it and sends the result back, then continues the conversation. This cycle (call → execute → continue) repeats until the model produces a final text response with no more tool calls.

Think of a tool like a database query the model can issue: you define the query interface (name, inputs, what it returns), and the model decides when to run it.

| Library handles | You implement |
|---|---|
| Invocation decision (model chooses when to call the tool) | Tool class with `tool_name`, `description`, `param`, `call` |
| Dispatch, result injection into conversation, error recovery | `call(**inputs)` — return a string (never raise) |
| JSON schema generation from `param` DSL | `instance_tools` on the agent if tool needs per-call state |
| `tool_call.active_ai` instrumentation | — |

---

## Generating a tool

```bash
rails generate active_ai:tool PriceCheck
# creates app/ai/tools/price_check_tool.rb
# creates test/ai/tools/price_check_tool_test.rb
```

The generator guards against reserved built-in names (`web_search`, `read_webpage`) — use `ActiveAI::Tools::WebSearch` directly instead of generating those.

---

## Defining a tool

Inherit from `ApplicationTool` (which inherits from `ActiveAI::Tool::Base`):

```ruby
class PriceCheckTool < ApplicationTool
  tool_name   "price_check"
  description "Look up the current price of a product by SKU."

  param :sku, type: :string, description: "The product SKU to look up"

  def call(sku:)
    product = Product.find_by(sku: sku)
    return "Product not found." unless product
    "$#{product.price}"
  end
end
```

**Required DSL declarations:**

| DSL | Description |
|---|---|
| `tool_name "..."` | The name the model uses to invoke this tool |
| `description "..."` | What the tool does (shown to the model) |
| `param :name, type:, description:` | Declares one input parameter |
| `def call(**inputs)` | The implementation; return value becomes the tool result sent back to the model |

**`param` DSL:**

Each `param` call adds one parameter to the tool's input schema:

```ruby
param :query,   type: :string,  description: "The search query"
param :limit,   type: :integer, description: "Max results to return"
param :verbose, type: :boolean, description: "Whether to include extra detail", required: false
```

`required:` defaults to `true`. Optional parameters are excluded from the `required` array in the JSON schema sent to the provider, letting the model omit them.

**Backwards-compatible hash style:**

The older `def self.parameters` hash style still works if you need it — all keys are treated as required:

```ruby
def self.parameters
  {
    query: { type: "string", description: "The search query" }
  }
end
```

Prefer the `param` DSL for new tools — it supports optional parameters and produces cleaner code.

---

## Registering tools on an agent

**Class-based (stateless):**

```ruby
class ResearchAgent < ApplicationAgent
  tool PriceCheckTool
  tools ActiveAI::Tools::WebSearch
end
```

**Instance-based (stateful — tool needs runtime context):**

```ruby
class WritingAgent < ApplicationAgent
  def initialize(document:, **kwargs)
    @document = document
    super(**kwargs)
  end

  def instance_tools
    return [] unless @document
    [
      WriteDocumentSectionTool.new(document: @document),
      InsertDocumentSectionTool.new(document: @document)
    ]
  end
end
```

Use `instance_tools` when the tool needs access to an object that only exists at call time (a document, a user, a record). `all_tools` merges class-level tools and instance tools — the provider sees all of them.

---

## Tool results

The return value of `call` is what the model receives as the tool result. Return a string — plain text, JSON, Markdown, or any format the model can read.

For errors, return a descriptive string rather than raising — raising from `call` propagates up and aborts the stream. If a tool encounters a missing record or external failure, returning `"Product not found."` gives the model a chance to recover gracefully.

---

## Tools with their own LLM calls

A tool can make its own LLM call using the `complete` method on `Tool::Base`. This is useful for summarization, classification, or extraction inside a tool:

```ruby
class SummarizeTool < ApplicationTool
  tool_name   "summarize"
  description "Summarize a block of text."

  provider     :anthropic
  model        "claude-haiku-4-5-20251001"
  system_prompt "You are a summarizer. Return a 2-sentence summary."

  param :text, type: :string, description: "Text to summarize"

  def call(text:)
    complete(text)
  end
end
```

`complete(prompt)` makes a blocking call using the tool's declared provider/model/system_prompt and returns the response string.

---

## Accessing instrumentation

Each tool call fires a `tool_call.active_ai` notification:

```ruby
ActiveSupport::Notifications.subscribe("tool_call.active_ai") do |event|
  Rails.logger.info "[Tool] #{event.payload[:tool_name]} (#{event.duration.to_i}ms)"
end
```

Payload: `{ agent_class:, tool_name:, input:, result: }`

See [docs/streaming.md](streaming.md) for the full event reference.
