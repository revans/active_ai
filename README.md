# ActiveAI

ActiveAI is a Rails-first AI agent library. It does for LLM calls what ActionMailer does for email — gives them a declared, testable home with provider-agnostic abstractions, a built-in agentic loop, streaming support, and Rails instrumentation.

Without ActiveAI, LLM calls end up scattered across controllers and service objects, each reinventing how to format messages, handle tool calls, route to the right provider, and stream responses. ActiveAI centralizes that plumbing into one class hierarchy so individual agent classes stay declarative and thin.

> **Status: Active development.** APIs, DSLs, generator output, and memory pipeline internals are subject to breaking changes between versions. This gem is in active use and testing — production deployment is at your own risk.

---

## How it maps to Rails conventions

| ActiveAI | Rails analogy |
|---|---|
| `ActiveAI::Agent::Base` | `ActionMailer::Base` |
| `ApplicationAgent` | `ApplicationMailer` |
| `WritingAgent` | `UserMailer` |
| `ActiveAI::Provider::Anthropic` | SMTP delivery method |
| `config/ai.yml` | `config/database.yml` |
| `ActiveAI.configure` | `config.action_mailer` |

---

## Installation

Add to your Gemfile:

```ruby
gem "active_ai", path: "gems/active_ai"
```

Run the install generator:

```bash
rails generate active_ai:install
```

This creates:

- `app/ai/agents/application_agent.rb` — your base agent class
- `app/ai/tools/application_tool.rb` — your base tool class
- `app/ai/skills/application_skill.rb` — your base skill class
- `app/ai/workflows/application_workflow.rb` — your base workflow class
- `app/ai/orchestrators/application_orchestrator.rb` — your base orchestrator class
- `config/ai.yml` — provider and model defaults per environment
- `config/initializers/active_ai.rb` — runtime configuration hook

---

## Quick start

```ruby
class WritingAgent < ApplicationAgent
  tools ActiveAI::Tools::WebSearch

  def initialize(document:, **kwargs)
    @document = document
    super(**kwargs)
  end
end

# Blocking call
response = WritingAgent.new(document: @doc, message: "Summarize this.").complete

# Streaming call
WritingAgent.new(document: @doc, message: "Summarize this.").stream do |event|
  send_to_client(event) if event.is_a?(String)
end
```

---

## Features

| Feature | Description | Doc |
|---|---|---|
| Configuration | `config/ai.yml`, `ActiveAI.configure`, API key chain | [docs/configuration.md](docs/configuration.md) |
| Agents | Base class, DSL, agentic loop | [docs/agents.md](docs/agents.md) |
| Skills | Behavioral instruction blocks | [docs/skills.md](docs/skills.md) |
| Tools | Custom executable functions | [docs/tools.md](docs/tools.md) |
| Built-in Tools | WebSearch, WebPageReader | [docs/built-in-tools.md](docs/built-in-tools.md) |
| Providers | Anthropic, OpenAI, xAI, custom | [docs/providers.md](docs/providers.md) |
| Prompt Files | ERB templates, partials, namespaced loading | [docs/prompt-files.md](docs/prompt-files.md) |
| Workflows | Multi-agent sequential coordination | [docs/workflows.md](docs/workflows.md) |
| Orchestration | Meta-agent routing to agents and workflows | [docs/orchestration.md](docs/orchestration.md) |
| Memory | Recall, persist, vector search, injection | [docs/memory.md](docs/memory.md) |
| Streaming | SSE streaming in controllers | [docs/streaming.md](docs/streaming.md) |
| Credentials | Per-user API key storage | [docs/credentials.md](docs/credentials.md) |
| Generators | All generator commands | [docs/generators.md](docs/generators.md) |
| Testing | TestHelper, stubs, fixtures | [docs/testing.md](docs/testing.md) |

---

## Error classes

| Class | When raised |
|---|---|
| `ActiveAI::Error` | Base class for all ActiveAI errors |
| `ActiveAI::ConfigurationError` | Unknown provider, missing API key, duplicate tool names, or other misconfiguration |
| `ActiveAI::ProviderError` | Provider API error; message is prefixed with the provider name (`"Anthropic: ..."`, `"OpenAI: ..."`, `"xAI: ..."`) and wraps the original via `.cause` |
| `ActiveAI::ToolLoopError` | Agentic loop exceeded `MAX_TOOL_ITERATIONS` without a final text response |
| `ActiveAI::Tools::NotConfiguredError` | Built-in tool used without required configuration |
| `ActiveAI::MissingPromptError` | Prompt file not found at the expected path; raised as `PromptResolver::PromptNotFound < MissingPromptError`, so `rescue ActiveAI::Error` catches it |

---

## Requirements

- Ruby >= 3.2
- Rails >= 7.0
- `gem "anthropic"` — required for Anthropic provider
- `gem "ruby-openai"` — required for OpenAI and xAI providers
- `gem "neighbor"` — required for pgvector memory (installed by `active_ai:memory:install --vector=pgvector`)
