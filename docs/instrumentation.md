# Instrumentation

ActiveAI instruments every significant operation via `ActiveSupport::Notifications`. Think of it like the flight recorder on an aircraft — every agent turn, tool dispatch, workflow step, and skill resolution fires an event with a rich payload, whether or not anything is listening. You attach subscribers only when you need them.

All events follow Rails convention: `action.active_ai`. `ActiveAI::LogSubscriber` is attached automatically and logs to `Rails.logger`.

---

## Event reference

### `agent_complete.active_ai`

Fires once per `agent.complete` call — the full agent turn including any tool-call iterations.

| Key | Type | Description |
|---|---|---|
| `:agent_class` | String | Name of the agent class |
| `:provider` | Symbol | Provider used (`:anthropic`, `:openai`, `:xai`) |
| `:model` | String | Model name |
| `:messages` | Array | Messages array sent to the provider on the final iteration |
| `:system_prompt` | String | Resolved system prompt |
| `:response` | String | Accumulated text response |
| `:usage` | Hash | Token counts — `:input_tokens`, `:output_tokens`, cache keys |
| `:tool_calls` | Array | All tool calls made during this turn `[{ id:, name:, result: }]` |
| `:caller_type` | Symbol\|nil | Type of the caller if called from a workflow or orchestrator |
| `:caller_name` | String\|nil | Class name of the caller |

---

### `agent_stream.active_ai`

Fires inside `agent_complete.active_ai` — wraps the raw stream loop. Useful for lower-level timing or when you need per-stream metrics separate from the full turn.

| Key | Type | Description |
|---|---|---|
| `:agent_class` | String | Name of the agent class |
| `:provider` | Symbol | Provider used |
| `:model` | String | Model name |
| `:usage` | Hash | Token counts after the final stream iteration |
| `:tool_calls` | Array | Tool calls made during this stream |

---

### `orchestrator_route.active_ai`

Fires once per `orchestrator.complete` call — the routing decision, including which agents or workflows were dispatched.

| Key | Type | Description |
|---|---|---|
| `:orchestrator_class` | String | Name of the orchestrator class |
| `:provider` | Symbol | Provider used |
| `:model` | String | Model name |
| `:message` | String | The input message |
| `:response` | String | The orchestrator's text response (if any) |
| `:usage` | Hash | Token counts |
| `:dispatched_to` | Array | Names of agents/workflows called via meta-tools `["writing_agent"]` |
| `:caller_type` | Symbol\|nil | Type of the caller |
| `:caller_name` | String\|nil | Class name of the caller |

---

### `orchestrator_dispatch.active_ai`

Fires once per meta-tool invocation — each time the orchestrator routes to an individual agent or workflow.

| Key | Type | Description |
|---|---|---|
| `:source_class` | String | Orchestrator class that dispatched |
| `:step_name` | String | Underscored name of the target (`"writing_agent"`) |
| `:input_length` | Integer | Character length of the message passed |
| `:output_length` | Integer | Character length of the result |
| `:caller_type` | Symbol\|nil | Caller context (usually `:orchestrator`) |
| `:caller_name` | String\|nil | Caller class name |

---

### `workflow_run.active_ai`

Fires once per `WorkflowClass.run(input)` call. Only fires for the class-level convenience entry point — `WorkflowClass.new.run(input)` bypasses it.

| Key | Type | Description |
|---|---|---|
| `:workflow_class` | String | Name of the workflow class |
| `:input` | String | The input string passed to `run` |
| `:output` | String | The return value of `run` |
| `:caller_type` | Symbol\|nil | Type of the caller |
| `:caller_name` | String\|nil | Class name of the caller |

---

### `workflow_step.active_ai`

Fires once per `step(...)` call within a workflow.

| Key | Type | Description |
|---|---|---|
| `:source_class` | String | Workflow class that called `step` |
| `:step_name` | String | Class name of the agent or tool that ran |
| `:input_length` | Integer | Character length of the `:message` kwarg |
| `:output_length` | Integer | Character length of the result |
| `:usage` | Hash\|nil | Token counts from the agent; `nil` for tool steps |
| `:caller_type` | Symbol\|nil | Caller context |
| `:caller_name` | String\|nil | Caller class name |

---

### `workflow_parallel_step.active_ai`

Fires once per `parallel_step(...)` call, wrapping the entire concurrent batch.

| Key | Type | Description |
|---|---|---|
| `:workflow_class` | String | Workflow class that called `parallel_step` |
| `:steps` | Array | Class names of all targets in the batch |
| `:count` | Integer | Number of concurrent steps |
| `:results_count` | Integer | Number of results returned |

---

### `tool_call.active_ai`

Fires once per tool invocation inside the agentic loop. The `result` key is set even when the tool raises — the error is captured as a string and returned to the model.

| Key | Type | Description |
|---|---|---|
| `:tool_name` | String | The tool's declared name (matches the JSON schema `name`) |
| `:tool_class` | String | Ruby class name of the tool |
| `:input` | Hash | Arguments the model passed to the tool |
| `:result` | String | Return value (or `"Error: ClassName — message"` on exception) |
| `:caller_type` | Symbol\|nil | Type of the caller |
| `:caller_name` | String\|nil | Class name of the caller |

---

### `skill_resolve.active_ai`

Fires each time a skill's content is resolved for inclusion in a prompt — once per agent turn per skill.

| Key | Type | Description |
|---|---|---|
| `:skill_name` | String | The skill's declared name |
| `:skill_class` | String | Ruby class name |
| `:content_length` | Integer | Character length of the resolved content |
| `:caller_type` | Symbol\|nil | Type of the caller |
| `:caller_name` | String\|nil | Class name of the caller |

---

## Subscribing to events

```ruby
# Log every agent turn to your own table
ActiveSupport::Notifications.subscribe("agent_complete.active_ai") do |event|
  AgentLog.create!(
    agent:        event.payload[:agent_class],
    model:        event.payload[:model],
    input_tokens: event.payload.dig(:usage, :input_tokens),
    output_tokens: event.payload.dig(:usage, :output_tokens),
    duration_ms:  event.duration.round
  )
end

# Track every tool call
ActiveSupport::Notifications.subscribe("tool_call.active_ai") do |event|
  ToolUsageLog.create!(
    tool:        event.payload[:tool_name],
    called_by:   event.payload[:caller_name],
    duration_ms: event.duration.round
  )
end
```

Put subscriptions in a Rails initializer (`config/initializers/active_ai_instrumentation.rb`).

---

## Caller context

When a workflow calls an agent, or an orchestrator dispatches to a workflow, each notification carries `:caller_type` and `:caller_name` in its payload — automatically, with no plumbing in your code.

```
WorkflowClass.run("input")
  └─ workflow_run.active_ai          caller_type: nil
     └─ step(WritingAgent, ...)
        └─ workflow_step.active_ai   caller_type: :workflow, caller_name: "ResearchWorkflow"
           └─ agent_complete.active_ai  caller_type: :workflow, caller_name: "ResearchWorkflow"
              └─ tool_call.active_ai    caller_type: :agent,    caller_name: "WritingAgent"
```

This is implemented via `ActiveAI::Instrumentation` — a thread-local stack that each component pushes itself onto before yielding control. You can read the current caller anywhere:

```ruby
ActiveAI::Instrumentation.current_caller
# => { type: :agent, name: "WritingAgent" }
```

Or push your own context for custom instrumentation:

```ruby
ActiveAI::Instrumentation.with_caller(type: :job, name: "MyBackgroundJob") do
  WritingAgent.run("write something")
  # agent_complete.active_ai will carry caller_type: :job, caller_name: "MyBackgroundJob"
end
```
