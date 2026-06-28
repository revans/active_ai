# Streaming

`ActiveAI::Concerns::Streamable` is a controller mixin that wires agent streaming to HTTP server-sent events (SSE). Include it in any controller that needs to stream AI responses to a client.

Think of it like ActionController::Live, but with the agent lifecycle (tool calls, memory hooks, cleanup) already handled.

| Library handles | You implement |
|---|---|
| SSE headers, event serialization, `[DONE]` sentinel | `include Streamable` in controller, call `stream_agent(agent)` |
| Client disconnect — partial response preserved | `after_stream` block — persisting the full response |
| `stream.active_ai` and `tool_call.active_ai` events | `after_stream_memory_persist` override if enqueuing memory jobs |

The memory persist hook is a **no-op by default**. If you don't override `after_stream_memory_persist`, nothing is enqueued — memory never persists. See [memory.md](memory.md).

---

## Setup

```ruby
class MessagesController < ApplicationController
  include ActiveAI::Concerns::Streamable

  def create
    agent = WritingAgent.new(
      document: @document,
      history:  message_history,
      message:  params[:message]
    )

    stream_agent(agent) do |full_response|
      Message.create!(role: "assistant", content: full_response)
    end
  end
end
```

`stream_agent` sets the correct SSE headers, runs the agent's agentic loop, writes events to the response as they arrive, and calls the block with the full accumulated response once the stream ends.

---

## `stream_agent(agent, &after_stream)`

| Argument | Description |
|---|---|
| `agent` | Any agent instance (must respond to `stream`) |
| `&after_stream` | Block called with the full response string after the stream completes |

**Headers set automatically:**

```
Content-Type: text/event-stream
Cache-Control: no-cache
X-Accel-Buffering: no
```

**Event format** — each event is written as:

```
data: {"chunk":"Hello, "}\n\n
data: {"tool_call":{"id":"tc_1","name":"web_search","input":{"query":"Rails 8"}}}\n\n
data: [DONE]\n\n
```

---

## Client-side handling (JavaScript)

```js
const source = new EventSource("/messages")

source.onmessage = (event) => {
  if (event.data === "[DONE]") {
    source.close()
    return
  }

  const data = JSON.parse(event.data)

  if (data.chunk) {
    appendToOutput(data.chunk)
  } else if (data.tool_call) {
    showToolCallIndicator(data.tool_call.name)
  }
}
```

---

## After-stream memory hook

Override `after_stream_memory_persist` to enqueue memory persistence after each conversation turn:

```ruby
class MessagesController < ApplicationController
  include ActiveAI::Concerns::Streamable

  private

  def after_stream_memory_persist(agent, full_response)
    ActiveAIMemoryPersistJob.perform_later(
      user:          Current.user,
      agent_class:   agent.class.name,
      subject:       @document,
      full_response: full_response
    )
  end
end
```

The base implementation is a no-op — override it only if you want async memory persistence after each stream.

---

## Client disconnects

If the client disconnects mid-stream, `stream_agent` catches the disconnect gracefully. The `after_stream` block still runs with whatever response was accumulated before the disconnect. This means database writes (saving the partial message) happen even on disconnect.

---

## Instrumentation events

Two `ActiveSupport::Notifications` events fire during a stream:

### `stream.active_ai`

Fires once per `stream` call. Payload:

```ruby
{
  agent_class: "WritingAgent",
  provider:    :anthropic,
  model:       "claude-sonnet-4-6",
  usage:       {
    input_tokens:          412,
    output_tokens:         89,
    cache_creation_tokens: 312,
    cache_read_tokens:     100,
    stop_reason:           "end_turn",
    provider_request_id:   "req_01Abc..."
  },
  tool_calls: [
    { id: "tc_1", name: "web_search", result: "..." }
  ]
}
```

### `tool_call.active_ai`

Fires once per tool execution. Payload:

```ruby
{
  agent_class: "WritingAgent",
  tool_name:   "web_search",
  input:       { query: "Rails 8 release notes" },
  result:      "## Rails 8\n..."
}
```

Subscribe in an initializer:

```ruby
ActiveSupport::Notifications.subscribe("stream.active_ai") do |event|
  AgentCall.create!(
    agent_class:   event.payload[:agent_class],
    provider:      event.payload[:provider],
    model:         event.payload[:model],
    input_tokens:  event.payload.dig(:usage, :input_tokens),
    output_tokens: event.payload.dig(:usage, :output_tokens),
    duration_ms:   event.duration.to_i
  )
end
```

---

## Log output

`ActiveAI::LogSubscriber` subscribes to both events and writes structured log lines:

```
ActiveAI stream claude-sonnet-4-6 (487.2ms | in=412 out=89 cache_write=312 cache_read=100 | tools=web_search)
ActiveAI tool web_search (212.1ms)
```

These appear in `log/development.log` automatically — no configuration needed.
