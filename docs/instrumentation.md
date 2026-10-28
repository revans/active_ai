# Instrumentation

ActiveAI instruments every significant operation via `ActiveSupport::Notifications`. Think of it like the flight recorder on an aircraft — every agent turn, tool dispatch, workflow step, and skill resolution fires an event with a rich payload, whether or not anything is listening. You attach subscribers only when you need them.

All events follow Rails convention: `action.active_ai`. `ActiveAI::LogSubscriber` is attached automatically and logs to `Rails.logger`.

---

## Tying prompts, answers and logs together

Every event, and every line the log subscriber writes, carries the same ids:

| Key | Means |
|---|---|
| `:run_id` | One per top-level ActiveAI call — an agent, workflow, orchestrator, tool or command called from outside ActiveAI. Everything nested under it shares it. A UUIDv7, so it sorts by time. |
| `:span_id` | One per component invocation (agent, tool, workflow, command) and one per provider call. |
| `:parent_span_id` | The span this one runs under, so the run can be rebuilt as a tree. |
| `:request_id` / `:job_id` | The Rails request or Active Job the run happened in, when there is one, so AI lines filter alongside the app's own. They sit beside `run_id`; one request can hold several runs. |

The ids are ActiveAI's own, minted before anything is sent. Before each provider call, `agent_request.active_ai` fires with the full request — prompt, tools and settings — under that call's `span_id`; when the answer comes back — or the call fails — `agent_turn.active_ai` fires under the same `span_id`, and the same entry lands in `Response#turn_log`. The provider's own id (`provider_request_id`) is recorded beside them when the provider answered. It is never the key: a call that timed out has none, and its prompt is still on record.

To keep the full picture, store the payloads: `rails generate active_ai:event_log` creates the table, model and subscriber (see [generators](generators.md#active_aievent_log)), or subscribe yourself. The log subscriber writes the ids and counts only, never prompt text, model output or row data:

```ruby
ActiveSupport::Notifications.subscribe(/\.active_ai\z/) do |name, _start, _finish, _id, payload|
  AiEvent.create!(name: name, run_id: payload[:run_id], span_id: payload[:span_id],
                  parent_span_id: payload[:parent_span_id], payload: payload.except(:context))
end
```

Use a run id of your own with `ActiveAI::Instrumentation.with_run(run_id: "...") { ... }`. Save `agent.run_id` (or `response.run_id`) with whatever the app keeps from a run — a message, an audit row — to find the run again. `stream_agent` runs as one run, including its `after_stream` and `on_error` blocks, and keeps the Rails `request_id` under `ActionController::Live`'s own thread.

## Event reference

### `agent_request.active_ai`

Fires before every provider call, sharing its `span_id` with the `agent_turn.active_ai` that follows. Between them, a stream's request events carry everything ActiveAI hands the provider — the provider builds its HTTP body from exactly these — each piece once: the settings on the first request of the stream (they do not change within it), and on every request only the messages added since the one before. `AiEvent.request_for(span_id)` (from [`active_ai:event_log`](generators.md#active_aievent_log)) rebuilds the full request a call sent. To rebuild one yourself, take the stream's requests — same `run_id` and `parent_span_id` — in `turn` order, append their `messages`, and check each `messages_before` against the count so far.

| Key | Type | Description |
|---|---|---|
| `:agent_class` | String | Name of the agent class |
| `:provider` | Symbol | Provider the call goes to |
| `:model` | String | Model requested |
| `:turn` | Integer | 1 for the first provider call of the run, then 2, and so on |
| `:messages_before` | Integer | Messages earlier requests of this stream already carried |
| `:messages` | Array | The messages added since the previous request: on the first, the whole conversation; after a tool turn, the assistant's turn and the tool results |
| `:system` | String | The system prompt *(first request of a stream only, as are the keys below down to `:cacheable`)* |
| `:skills` | Array | Skills sent with it, `{ name:, content: }` |
| `:source_files` | Array | Source files sent with it |
| `:tools` | Array | Full definitions of the tools offered: name, description, input schema |
| `:max_tokens` | Integer\|nil | Output limit (`nil` for `:unlimited`) |
| `:response_schema` | Hash\|nil | The structured-output schema, when the agent declares one |
| `:options` | Hash\|nil | Provider options (`provider_options`) for this provider |
| `:cacheable` | Hash | Which sections were marked for prompt caching |
| `:context` | Hash | Whatever the agent's `#call_context` returns |

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

### `agent_usage.active_ai`

Fires once per call (`complete`, `generate` or `stream`) with the tokens **every** provider call in it used, whether or not the call finished. Use this one to count what you are spending: unlike `agent_complete.active_ai`, whose `:usage` is only the final turn, this event adds the turns of a tool loop together, and it still fires when a later turn raises, so tokens spent on an answer you discarded or an error you rescued are not lost. It does not fire when the provider reported no usage at all (a turn that fails before the provider answers has nothing to count).

| Key | Type | Description |
|---|---|---|
| `:agent_class` | String | Name of the agent class |
| `:provider` | Symbol | Provider used |
| `:model` | String | Model requested |
| `:usage` | Hash | Token counts added up over every turn: `:input_tokens`, `:output_tokens`, `:cache_creation_tokens`, `:cache_read_tokens`, `:reasoning_tokens` |
| `:turns` | Integer | How many provider calls the tool loop made |
| `:per_turn` | Array | Each turn's own usage hash, in order |
| `:completed` | Boolean | `false` when the call raised |
| `:context` | Hash | Whatever the agent's `#call_context` returns, so you can say whose call it was |

```ruby
class ApplicationAgent < ActiveAI::Agent::Base
  def call_context = { user_id: @user.id }
end

ActiveSupport::Notifications.subscribe("agent_usage.active_ai") do |event|
  Ledger.record!(user_id: event.payload.dig(:context, :user_id), usage: event.payload[:usage])
end
```

Provider differences to remember when adding tokens up: OpenAI's `:input_tokens` already includes cached tokens (`:cache_read_tokens` is a part of it), and `:reasoning_tokens` is a part of `:output_tokens`. Anthropic reports cache reads and writes **in addition to** `:input_tokens`.

---

### `agent_turn.active_ai`

Fires after **every provider call** in a run, as soon as the call returns and before any tool it asked for runs. Use it to
keep everything an agent says. A run with tools makes several calls, and `agent_complete.active_ai` only reports the whole
run; this one hands you each turn's words on their own, in order, so the narration before a tool call is saved as its own
entry and nothing later (a failing tool, a failing second call) can lose it. If a call breaks off mid-answer, the words
already said are published too, with `:interrupted` set.

| Key | Type | Description |
|---|---|---|
| `:agent_class` | String | Name of the agent class |
| `:provider` | Symbol | Provider used |
| `:turn` | Integer | 1 for the first provider call, then 2, and so on |
| `:text` | String | Every word the model said this turn, in order (`""` when it went straight to a tool) |
| `:tool_calls` | Array | The tools it asked for this turn: `[{ id:, name:, input: }]` |
| `:usage` | Hash\|nil | This turn's own token counts |
| `:model` | String\|nil | The model that served this turn |
| `:finish_reason` | String\|nil | The provider's own word for why the turn stopped |
| `:final` | Boolean | `true` for the turn that gave the answer |
| `:interrupted` | Boolean | `true` when the call broke off before it finished |
| `:span_id` | String | The provider call's span — the same as its `agent_request.active_ai` |
| `:provider_request_id` | String\|nil | The provider's id for the call, when it answered |
| `:error` | String\|nil | `"Class: message"` when the call failed |
| `:context` | Hash | Whatever the agent's `#call_context` returns |

```ruby
ActiveSupport::Notifications.subscribe("agent_turn.active_ai") do |event|
  payload = event.payload
  Transcript.create!(run_id: payload.dig(:context, :run_id), turn: payload[:turn], said: payload[:text], tool_calls: payload[:tool_calls])
end
```

The same entries come back as `response.turn_log`, and as `agent.turn_log` after a run that raised.

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

Fires once per workflow run, through `WorkflowClass.run(input)` or `WorkflowClass.new.run(input)` — `ActiveAI::Workflow::Base` wraps every subclass's `run`.

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

Fires once per tool call, however the tool is invoked: from an agent's tool loop, a workflow step, or `tool.call(...)` directly. `ActiveAI::Tool::Base` wraps every subclass's `call`, so a new tool needs no instrumentation code, and a subclass calling `super` still fires one event. The `result` key is set even when the tool raises — the error is captured as a string (the agent loop returns it to the model). Anything the tool calls in turn sees `caller_type: :tool`. A tool name the model invents, with no tool behind it, fires with `tool_class: nil` and `result: "Unknown tool: ..."`.

| Key | Type | Description |
|---|---|---|
| `:tool_name` | String | The tool's declared name (matches the JSON schema `name`) |
| `:tool_class` | String | Ruby class name of the tool |
| `:input` | Hash | Arguments the model passed to the tool |
| `:result` | String | Return value (or `"Error: ClassName — message"` on exception) |
| `:caller_type` | Symbol\|nil | Type of the caller |
| `:caller_name` | String\|nil | Class name of the caller |

---

### `record_query.active_ai`

Fires once per `ActiveAI::Tools::RecordQuery` call, inside its `tool_call.active_ai`. It says what the model asked to read and what happened, for an audit of what an LLM read on whose behalf. **It never carries the rows.**

| Key | Type | Description |
|---|---|---|
| `:root_class` | String | Model of the `roots:` relation |
| `:root_id` | String | Root id the model asked for |
| `:association` | String\|nil | Association read; `nil` for a catalog call |
| `:scopes` | Array | Scopes the model asked for, as sent |
| `:limit` | Integer\|nil | Limit the model asked for |
| `:context` | Object | The tool's `context:` (typically the user) |
| `:outcome` | Symbol | `:read`, `:catalog` or `:refused` |
| `:returned` | Integer | Rows returned (`:read`) |
| `:total` | Integer | Exact number of matching records (`:read`) |
| `:truncated` | Boolean | More rows existed than were returned (`:read`) |
| `:associations` | Array | Associations listed (`:catalog`) |
| `:reason` | String | Why it was refused (`:refused`): not found, not readable, a write attempt, a timeout |

---

### `command_call.active_ai`

Fires once per command, however it is invoked. `ActiveAI::Command::Base` wraps every subclass's `call`.

| Key | Type | Description |
|---|---|---|
| `:command_name` | String | The command's declared name |
| `:command_class` | String | Ruby class name of the command |
| `:argument` | String\|nil | The argument captured from the typed trigger |
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

This is implemented via `ActiveAI::Instrumentation` — a thread-local stack that each component pushes itself onto before yielding control. `parallel_step` carries the stack into each thread it starts, so a step's events still name the workflow. A thread you start yourself begins with no run and an empty stack; carry both with `snapshot = ActiveAI::Instrumentation.capture` before spawning and `ActiveAI::Instrumentation.restore(snapshot) { ... }` inside the thread. You can read the current caller anywhere:

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
