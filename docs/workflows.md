# Workflows

A workflow coordinates multiple agent calls in a defined sequence without making LLM calls itself. Think of a workflow like a conductor: it doesn't play an instrument, but it tells each musician when to play and passes what one produces to the next.

Use a workflow when you need a fixed pipeline: research → draft → review. Use an Orchestrator when the routing logic itself should be decided by a model at runtime.

| Library handles | You implement |
|---|---|
| `step` dispatch — agent calls, tool calls, notifications | Workflow class with `run(input)` method |
| `parallel_step` — threading, result ordering | Sequence and step ordering logic |
| `step.active_ai` and `parallel_step.active_ai` notifications | Thread-local state (`Current.*`) when using `parallel_step` |
| Passing step output (string) to the next call | — |

---

## Defining a workflow

Inherit from `ApplicationWorkflow` (which inherits from `ActiveAI::Workflow`):

```ruby
class ResearchAndDraftWorkflow < ApplicationWorkflow
  description "Research a topic and draft a structured article."

  def run(input)
    research = step(ResearchAgent, message: input)
    draft    = step(DraftingAgent,  message: "Write an article based on:\n#{research}")
    draft
  end
end
```

`run` receives the initial input string and returns the final output string. Everything in between is up to you.

---

## `step`

Runs one agent or tool and returns its output:

```ruby
result = step(AgentClass, message: "What is Rails 8?", **context_kwargs)
```

`step` accepts:

- **Agent class** — calls `AgentClass.new(**kwargs).complete` (same as `AgentClass.run(message, **context_kwargs)`)
- **Tool class** — calls `ToolClass.call(**kwargs)` (stateless class-level call)
- **Tool instance** — calls `tool_instance.call(**kwargs)`

Each `step` fires a `step.active_ai` notification with:
- `workflow_class`, `agent_class`
- `input_length`, `output_length`
- `usage` (for agent steps — includes token counts)

---

## `parallel_step`

Runs multiple steps concurrently in threads and returns their results in order:

```ruby
results = parallel_step(
  [ResearchAgent, { message: "Find recent news about AI." }],
  [FactCheckAgent, { message: "Verify these claims: #{claims}" }]
)

research   = results[0][:response]
fact_check = results[1][:response]
```

Each entry is `[TargetClass, { kwargs }]`. Results come back as an array of `{ agent:, response: }` hashes, in the same order as the input.

Each step fires its own `step.active_ai` notification. All steps are also wrapped in a single `parallel_step.active_ai` notification.

**Thread safety:** each step runs in its own thread. If your agents use shared mutable state (e.g., `Current` attributes), make sure that state is established before calling `parallel_step`.

---

## Calling a workflow

**Class method:**

```ruby
result = ResearchAndDraftWorkflow.run("Write about the history of Rails.")
```

**Instance method:**

```ruby
workflow = ResearchAndDraftWorkflow.new
result   = workflow.run("Write about the history of Rails.")
```

---

## Passing context between steps

The return value of each `step` is a plain string. Pass it as the `message:` or interpolate it into a message for the next step:

```ruby
def run(input)
  outline  = step(OutlineAgent,  message: input)
  sections = step(WritingAgent,  message: "Write sections for this outline:\n#{outline}")
  review   = step(ReviewAgent,   message: "Review and improve:\n#{sections}")
  review
end
```

---

## Registration

Setting `description` on a workflow class registers it in `ActiveAI.registry` and makes it available to an Orchestrator:

```ruby
ActiveAI.workflows   # => [ResearchAndDraftWorkflow, ...]
```

See [orchestration.md](orchestration.md) for how to route to workflows via an Orchestrator.
