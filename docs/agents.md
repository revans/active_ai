# Agents

An agent is a class that wraps one LLM conversation context. It declares its provider, model, tools, skills, and caching strategy at the class level. Instances hold the per-call state (history, context, message) and run the conversation.

Think of it like a database connection: the connection pool configuration lives on the class, and each instance is a single connection used for one conversation turn.

---

## Generating an agent

```bash
rails generate active_ai:agent Writing
# creates app/ai/agents/writing_agent.rb
```

Generated agents inherit from `ApplicationAgent`, which is your app-level base class (itself inheriting from `ActiveAI::Base`).

---

## Class-level DSL

All declarations on the class are inherited by subclasses and can be overridden at any level.

### `provider`

Sets the LLM provider for this agent:

```ruby
provider :anthropic   # or :openai, :xai, or any registered custom provider
```

### `model`

Sets the model name and optional max output tokens:

```ruby
model "claude-sonnet-4-6", max_tokens: 8096
```

`max_tokens` defaults to `ActiveAI.config.max_tokens` if not declared.

The model can also be a callable — useful when the model should be resolved at call time (e.g., from a database record):

```ruby
model -> { Setting.instance.anthropic_model || "claude-sonnet-4-6" }
```

### `system_prompt`

Sets a static system message directly on the class:

```ruby
system_prompt "You are a writing assistant. Be concise and direct."
```

For longer prompts, use a prompt file instead — see [prompt-files.md](prompt-files.md).

### `cache`

Declares which parts of the prompt should use provider-level caching (Anthropic prompt caching). Caching reduces latency and cost for content that doesn't change between calls.

```ruby
cache :system,       ttl: "1h"   # system prompt changes rarely
cache :source_files, ttl: "1h"   # source content changes rarely
cache :context,      ttl: "5m"   # document body changes more often
```

Valid block names: `:system`, `:source_files`, `:context`. TTL is advisory metadata passed to the provider — Anthropic respects it for cache invalidation hints.

### `tool`

Registers a tool (class or instance) the model can invoke:

```ruby
tool ActiveAI::Tools::WebSearch
tool ActiveAI::Tools::WebPageReader
tool MyCustomTool
tool WriteDocumentSectionTool.new(document: @doc)  # instance with injected context
```

Class-registered tools are shared across all instances. For tools that need per-call context (like a document reference), use `instance_tools` instead.

### `skills`

Registers behavioral instructions that shape how the model responds. Skills are prepended to the system prompt as separate instruction blocks:

```ruby
skills ToneSkill
skills [BlogStructureSkill, CitationStyleSkill]
skills "Always prefer active voice over passive voice."   # inline string
```

See [skills.md](skills.md) for details.

### `description`

Provides a human-readable description of what the agent does. Required when registering with an Orchestrator. Setting it also auto-registers the class in `ActiveAI.registry`:

```ruby
description "Drafts, edits, and structures written content inside a document."
```

### `recall_memory`

Opts the agent into the memory system. Retrieved memories are prepended to the system prompt as soft-signal context:

```ruby
recall_memory strategy: :warm, token_budget: 600
```

See [memory.md](memory.md) for details.

---

## Instance interface

### `initialize`

`ApplicationAgent#initialize` accepts these keyword arguments:

| Argument | Type | Description |
|---|---|---|
| `message:` | string | The user's current message |
| `system:` | string | Overrides the class-level `system_prompt` for this call |
| `context:` | string | Prepended as a read user/assistant exchange (for passing large content) |
| `source_files:` | array | Array of file-like objects with caching support |
| `history:` | array | Prior message objects (must respond to `.role`, `.content`) |
| `skills:` | array | Per-call skill instances merged with class-level skills |
| `focus:` | string | Selected text to prepend to the message |
| `file_name:` | string | Attached file name to prepend to the message |
| `file_content:` | string | Attached file content to prepend to the message |
| `provider:` | string/symbol | Runtime provider override |
| `model:` | string | Runtime model override |

Subclasses can declare their own `initialize` to accept domain objects, then call `super`:

```ruby
class WritingAgent < ApplicationAgent
  def initialize(document:, **kwargs)
    @document = document
    super(**kwargs)
  end
end
```

### `stream(&block)`

Runs the full agentic loop. Yields events as they arrive:

```ruby
agent.stream do |event|
  case event
  when String
    # text chunk — write to client
  when Hash
    # tool call: { tool_call: { id:, name:, input: } }
  end
end
```

The loop: calls the provider → if tool calls come back, executes them and sends results back → continues until the provider produces a final text response with no more tool calls.

### `complete`

Blocking version of `stream`. Runs the agentic loop and returns the full accumulated response string:

```ruby
response = agent.complete
```

### `to_canonical_params`

Returns the params hash that would be sent to the provider. Useful for inspecting what an agent will send without making an actual API call:

```ruby
params = agent.to_canonical_params
params[:system]    # => "You are a writing assistant..."
params[:messages]  # => [{ role: "user", content: "..." }]
params[:tools]     # => [{ name: "web_search", ... }]
```

### `last_usage`

Returns token usage from the most recent call:

```ruby
agent.last_usage
# => {
#      input_tokens: 412,
#      output_tokens: 89,
#      cache_creation_tokens: 312,
#      cache_read_tokens: 100,
#      stop_reason: "end_turn",
#      provider_request_id: "req_01Abc..."
#    }
```

### `last_tool_call_results`

Returns the tool results from the most recent `stream` call:

```ruby
agent.last_tool_call_results
# => [{ id: "tc_1", name: "web_search", result: "..." }]
```

---

## Instance tools

For tools that need per-call context (like a reference to the current document), override `instance_tools`:

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

`all_tools` merges class-level tools and instance tools automatically. The provider sees all of them in the `tools` array.

---

## Convenience class method

`ApplicationAgent` defines `run_with_message` for single-call invocations, used primarily by the Orchestrator:

```ruby
WritingAgent.run_with_message("Summarize this document.", document: @doc)
# => "Here is a summary..."
```

Internally this calls `new(message:, **context).complete`.
