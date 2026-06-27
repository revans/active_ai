# Orchestration

An Orchestrator is a meta-agent: it uses an LLM to decide *which* agent or workflow should handle a given input, then dispatches to it. Think of a router at a restaurant: the model reads the request, decides which chef should handle it, and passes it over.

Use an Orchestrator when the routing decision itself is dynamic — when you have multiple agents with different specialties and want the model to pick the right one. Use a Workflow when the sequence is fixed.

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

## `context_for`

Override to supply per-class runtime context when the orchestrator dispatches to an agent or workflow:

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

`context_for` is merged into the `run(message, **context)` call when the Orchestrator dispatches to that agent or workflow. This is how you inject domain objects (documents, projects, users) without the orchestrator needing to know about them directly.

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
