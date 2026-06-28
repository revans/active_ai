# Orchestration

An Orchestrator is a meta-agent: it uses an LLM to decide *which* agent or workflow should handle a given input, then dispatches to it. Think of a router at a restaurant: the model reads the request, decides which chef should handle it, and passes it over.

Use an Orchestrator when the routing decision itself is dynamic — when you have multiple agents with different specialties and want the model to pick the right one. Use a Workflow when the sequence is fixed.

| Library handles | You implement |
|---|---|
| LLM routing, meta-tool schema generation, agentic loop | Orchestrator class with registered `agent`/`workflow`/`tools` |
| Dispatching to agents and workflows via `run` | `context_for` or `context:` lambda for domain object injection |
| `step.active_ai` notifications for each dispatch | System prompt — inline `system_prompt` or file-based `prompt_file` |

---

## Defining an orchestrator

Inherit from `ApplicationOrchestrator` (which inherits from `ActiveAI::Orchestrator`):

```ruby
class WritingOrchestrator < ApplicationOrchestrator
  description "Routes writing requests to the right specialist agent."

  agent  WritingAgent
  agent  ResearchAgent
  agent  EditingAgent
  workflow ResearchAndDraftWorkflow
end
```

Each registered agent and workflow becomes a meta-tool the orchestrator's model can call. The orchestrator runs an agentic loop: the model calls a meta-tool → the orchestrator runs that agent/workflow → the result comes back as the tool result → the model produces a final response.

---

## System prompts

Because an orchestrator decides routing, its system prompt matters. It's where you describe the domain, the agents' specialties, the routing rules, and the conditions under which one agent should be preferred over another.

**Inline** — for simple orchestrators:

```ruby
system_prompt "You route writing requests. Use WritingAgent for prose, ResearchAgent for factual questions."
```

**File-based** — for complex routing logic or conditional branches:

```ruby
prompt_file :writing
# → app/ai/orchestrators/prompts/writing.md.erb
```

The file is rendered without instance context at each call (ERB templates that reference `@ivars` or methods will not work here — use static conditional logic in the template). Use `.md.erb` when the routing rules are long enough to be maintained separately from the class definition.

---

## `agent` and `workflow`

Register agents and workflows that the orchestrator can route to:

```ruby
agent WritingAgent                        # uses WritingAgent.description as the tool description
agent WritingAgent, description: "..."   # override the description shown to the orchestrator model
workflow ResearchAndDraftWorkflow
```

Each registered class must:
- Include `ActiveAI::Orchestratable` (done automatically in `ApplicationAgent` and `ApplicationWorkflow`)
- Implement `self.run(message, **context)` (inherited automatically from `ActiveAI::Base` by `ApplicationAgent`, and from `ActiveAI::Workflow` by `ApplicationWorkflow`)

---

## Registering regular tools

An Orchestrator can also register regular tools (like `WebSearch`) alongside agent and workflow meta-tools. The model can call any of them mid-turn:

```ruby
class ResearchOrchestrator < ApplicationOrchestrator
  tools ActiveAI::Tools::WebSearch        # regular tool — immediate execution
  agent FactCheckAgent                    # meta-tool — runs the full agent
  workflow ResearchAndDraftWorkflow       # meta-tool — runs the full workflow
end
```

Regular tools are registered with the inherited `tools` DSL from `ActiveAI::Base`. Agent and workflow meta-tools are registered with `agent` and `workflow`.

---

## Context: two approaches

The Orchestrator needs to supply domain objects (documents, users, records) to the agents it dispatches to. There are two ways.

### `context_for` method

Override to supply per-class context from the orchestrator's own state:

```ruby
class WritingOrchestrator < ApplicationOrchestrator
  agent WritingAgent
  agent ResearchAgent

  def context_for(klass)
    case klass
    when WritingAgent  then { document: @document }
    when ResearchAgent then { project: @project }
    else {}
    end
  end
end
```

### `context:` lambda on registration

Pass a lambda directly at registration time. It is `instance_exec`'d on the orchestrator at dispatch time, so it has access to instance variables:

```ruby
class WritingOrchestrator < ApplicationOrchestrator
  def initialize(message:, document:)
    super(message: message)
    @document = document
  end

  agent WritingAgent,  context: -> { { document: @document } }
  agent ResearchAgent  # no context: lambda — falls back to context_for
end
```

The `context:` lambda takes precedence over `context_for` for that class. Use `context_for` when context logic is shared or conditional across many agents; use `context:` when each agent has a simple, distinct need.

`context_for` is merged into the `run(message, **context)` call when the Orchestrator dispatches. This is how you inject domain objects without the orchestrator needing to forward them through the model.

---

## Calling an orchestrator

**Class method:**

```ruby
result = WritingOrchestrator.run("Write an introduction for my article about Rails.")
```

**Instance method:**

```ruby
orchestrator = WritingOrchestrator.new(message: "Write an introduction for my article about Rails.")
result       = orchestrator.complete
```

---

## Orchestratable

`ActiveAI::Orchestratable` is a marker mixin that makes a class dispatchable by an Orchestrator. `ApplicationAgent` and `ApplicationWorkflow` already include it.

The dispatching Orchestrator calls `klass.run(message, **context)` on each registered class. Agent classes inherit `run` from `ActiveAI::Base`; workflow classes inherit it from `ActiveAI::Workflow`. Custom base classes that want to be Orchestratable must include the module and implement `self.run(message, **context)`.

---

## How it works internally

1. `WritingOrchestrator.run(input)` creates an instance and calls `complete`.
2. The orchestrator builds its system prompt listing all registered agents/workflows with their descriptions.
3. Each agent/workflow is exposed as a meta-tool: `{ name: "writing_agent", description: "Drafts content", input_schema: { message: string } }`.
4. The model calls `writing_agent(message: "Write an intro.")`.
5. The orchestrator executes `WritingAgent.run("Write an intro.", **context_for(WritingAgent))`.
6. The result is returned as the tool result.
7. The model produces a final response.

From the outside, the call looks like any other agent call. The routing is invisible.
