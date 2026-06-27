# Testing

ActiveAI ships a `TestHelper` module and a set of testing conventions to keep agent tests fast and deterministic — no real API calls in the test suite.

---

## Setup

Include the test helper in your test base class:

```ruby
# test/test_helper.rb
require "active_ai/test_helper"

class ActiveSupport::TestCase
  include ActiveAI::TestHelper
end
```

---

## Stub helpers

### `stub_ai_response` — bypass the provider entirely

Replaces an agent's `stream` method for a single test, yielding a fixed response string. Use when you only care about what happens *after* the agent responds, not about the provider interaction:

```ruby
test "saves the assistant message after stream" do
  agent = WritingAgent.new(document: @document, message: "Summarize this.")
  stub_ai_response(agent, response: "Here is your summary.")

  agent.stream do |event|
    # receives "Here is your summary." as a single chunk
  end

  assert_equal "Here is your summary.", agent.complete
end
```

The stub calls the block exactly once with the full response string, then returns. `last_usage` returns nil. `last_tool_call_results` returns `[]`.

### `stub_provider` — simulate the agentic loop

Stubs the provider instance directly, letting you test the full agentic loop (tool dispatch, result accumulation) without a real API call. Use this when you need to verify tool execution:

```ruby
# Simple — provider returns a text response
stub_provider(agent, response: "Here is your answer.")

# With a tool call — provider first requests a tool, then responds
stub_provider(agent,
  response:   "Research complete.",
  tool_calls: [{ id: "t1", name: "web_search", input: { "query" => "Rails 8" } }])

agent.stream { }
assert_ai_tool_called agent, :web_search
assert_equal "Research complete.", agent.complete
```

`tool_calls` triggers a two-turn loop: turn 1 the provider requests the tool, turn 2 it produces the final response. Only affects the stubbed instance.

### `stub_memory_recall` — control what memories are injected

Stubs `ActiveAI::Memory.recall` to return a fixed set of memories, bypassing the database:

```ruby
# With a block — automatically restored when block exits
stub_memory_recall(memories: [memory]) do
  assert_agent_system_includes agent, "Be concise"
end

# Without a block — restore manually in teardown
stub_memory_recall(memories: [memory])
assert_agent_system_includes agent, "Be concise"
restore_memory_recall
```

Pass `memories: []` (the default) to assert that no memory is injected.

---

## Tool call assertions

### `assert_ai_tool_called`

Asserts a specific tool was invoked in the last `stream` call:

```ruby
test "invokes web_search when asked about current events" do
  agent = ResearchAgent.new(message: "What happened today in tech?")
  stub_provider(agent, response: "done", tool_calls: [{ id: "t1", name: "web_search", input: { "query" => "tech news" } }])
  agent.stream { }

  assert_ai_tool_called agent, :web_search
end
```

### `refute_ai_tool_called`

Asserts a specific tool was NOT invoked:

```ruby
agent.stream { }
refute_ai_tool_called agent, :web_search
```

### `assert_no_ai_tools_called`

Asserts no tools were invoked at all — useful for verifying clean, tool-free runs:

```ruby
agent.stream { }
assert_no_ai_tools_called agent
```

All three check `agent.last_tool_call_results` and do not assert what any tool returned.

---

## System prompt assertions

`assert_agent_system_includes` and `refute_agent_system_includes` call `to_canonical_params[:system]` and assert on the result — no provider call needed:

```ruby
test "memory block is prepended when memories exist" do
  stub_memory_recall(memories: [warm_memory]) do
    agent = WritingAgent.new(document: @document, message: "Write.")
    assert_agent_system_includes agent, "Historical context"
    assert_agent_system_includes agent, "Use short paragraphs"
  end
end

test "no memory block when recall is empty" do
  stub_memory_recall(memories: []) do
    agent = WritingAgent.new(document: @document, message: "Write.", system: "Be helpful.")
    refute_agent_system_includes agent, "Historical context"
  end
end
```

## Inspecting canonical params directly

For assertions not covered by the named helpers, read `to_canonical_params` directly:

```ruby
test "includes document context in messages" do
  agent = WritingAgent.new(document: @document, message: "Write a summary.")
  params = agent.to_canonical_params

  assert_includes params[:messages].map { |m| m[:content] }, @document.body
end

test "memory block is prepended to system prompt" do
  memory = ActiveAIMemory.create!(agent_class: "WritingAgent", ...)
  params = WritingAgent.new(document: @document, message: "Write.").to_canonical_params

  assert_includes params[:system], "Historical context"
ensure
  memory.destroy
end
```

`to_canonical_params` is safe to call in tests — it exercises the full build chain (memory recall, skill formatting, prompt file loading) without touching the network.

---

## Testing tools

Test tool `call` methods directly — no agent needed:

```ruby
class PriceCheckToolTest < ActiveSupport::TestCase
  setup do
    @tool = PriceCheckTool.new
  end

  test "returns the price for a known SKU" do
    product = products(:widget)
    assert_equal "$9.99", @tool.call(sku: product.sku)
  end

  test "returns not found for unknown SKU" do
    assert_equal "Product not found.", @tool.call(sku: "MISSING")
  end
end
```

---

## Testing skills

Test skill content in isolation:

```ruby
class ToneSkillTest < ActiveSupport::TestCase
  test "formal context produces formal tone instruction" do
    content = ToneSkill.content(context: "formal contract review")
    assert_includes content, "formal"
  end

  test "default context produces conversational tone" do
    content = ToneSkill.content
    assert_includes content, "conversational"
  end
end
```

---

## Fixtures for memory tests

The generator creates starter fixtures in `test/fixtures/active_ai_memories.yml`:

```yaml
writing_intro:
  subject_type: "Document"
  subject_id: 1
  agent_class: "WritingAgent"
  scope: "introduction"
  tier: "warm"
  summary:
    decisions:
      - description: "Use first-person voice"
        confidence: 0.9
    open_threads: []
    identity_updates: []
    resolved: []
    agent_observations: []
  token_estimate: 50
  access_count: 3
  last_accessed_at: "2026-01-15 10:00:00"
```

For tests that create memory records directly (to test specific recall behavior), create and destroy them in the test body rather than relying on fixtures — memory tests are often sensitive to the exact set of records present.

```ruby
test "warm memories for this document appear in system prompt" do
  memory = ActiveAIMemory.create!(
    agent_class:  "WritingAgent",
    subject_type: @document.class.name,
    subject_id:   @document.id,
    tier:         "warm",
    summary: { "decisions" => [{ "description" => "Use bullets", "confidence" => 0.9 }],
               "open_threads" => [], "identity_updates" => [], "resolved" => [], "agent_observations" => [] },
    last_accessed_at: 1.hour.ago
  )

  system_prompt = WritingAgent.new(document: @document, message: "Write.").to_canonical_params[:system]
  assert_includes system_prompt, "Use bullets"
ensure
  memory&.destroy
end
```

---

## Test configuration

By default, `config/ai.yml` sets a cheaper model in the test environment:

```yaml
test:
  <<: *default
  model: claude-haiku-4-5-20251001
```

Since `stub_ai_response` bypasses the provider entirely, the model name in the test environment only matters for tests that intentionally make real API calls (integration tests, acceptance tests). Keep those in a separate file or tag them so they can be skipped in CI.
