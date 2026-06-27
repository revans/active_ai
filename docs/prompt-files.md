# Prompt Files

Prompt files are ERB or plain Markdown files that live in your app's `app/ai/` directory tree. They let you author complex system prompts outside of Ruby strings — with full ERB rendering, partials, and skill includes.

Think of them like view templates for the AI layer: `app/views/` is to HTML what `app/ai/agents/prompts/` is to system messages.

---

## File locations

Prompts are organized by namespace, mirroring the directory structure of your AI layer:

| Namespace | Directory | Used by |
|---|---|---|
| `:agent` | `app/ai/agents/prompts/` | Agent classes |
| `:tool` | `app/ai/tools/prompts/` | Tool classes |
| `:skill` | `app/ai/skills/prompts/` | Shared skill content |
| `:memory` | `app/ai/memory/prompts/` | Memory-related agents |
| `:workflow` | `app/ai/workflows/prompts/` | Workflow classes |
| `:orchestrator` | `app/ai/orchestrators/prompts/` | Orchestrator classes |

---

## File extensions

ActiveAI checks for files in this order:

1. `[name].md.erb` — ERB template, rendered with context
2. `[name].md` — Plain Markdown, returned as-is

---

## Loading prompts in an agent

Include `ActiveAI::Promptable` (done automatically via `ApplicationAgent`) and declare the namespace:

```ruby
class ApplicationAgent < ActiveAI::Base
  include ActiveAI::Promptable
  prompt_namespace :agent
end
```

Then load a prompt inside `build_params` or `initialize`:

```ruby
class WritingAgent < ApplicationAgent
  private

  def build_params
    super.merge(system: prompt_file(:writing))
  end
end
```

`prompt_file(:writing)` loads `app/ai/agents/prompts/writing.md.erb` (or `.md`), renders it with the current agent instance as context, and returns the rendered string.

---

## Passing locals

Pass keyword arguments to make them available as local variables in the template:

```ruby
prompt_file(:writing, tone: "formal", audience: "executives")
```

In the template:

```erb
Write for a <%= audience %> audience.
Tone: <%= tone %>.
```

---

## Accessing instance state in templates

Because the template is rendered with the agent instance as context, all instance variables and methods are available:

```erb
You are helping with the document "<%= @document.title %>".
Current section: <%= @document.current_section %>.
```

---

## Partials

Include another prompt file from the same directory:

```erb
You are a writing assistant.

<%= partial(:tone_guidelines) %>
<%= partial(:citation_rules) %>
```

`partial(:tone_guidelines)` loads `app/ai/agents/prompts/tone_guidelines.md.erb` and inlines its content at that position. Partials can themselves use `partial` and `skill` — they render in the same context.

---

## Skill includes

Include a shared skill file from `app/ai/skills/prompts/`:

```erb
You are a writing assistant.

<%= skill(:active_voice) %>
<%= skill(:no_jargon) %>
```

`skill(:active_voice)` loads `app/ai/skills/prompts/active_voice.md.erb`. This lets you share skill content between prompt files and skill classes without duplication.

---

## Loading prompts outside of an agent

Use `Rails.active_ai` for simple prompt access anywhere in the app:

```ruby
Rails.active_ai.agent.prompt(:writing)   # => "You are a writing assistant..."
Rails.active_ai.skill.prompt(:tone)      # => "Write in a conversational tone..."
```

Note: `prompt` (without the `_file` suffix) renders without instance context — locals and `partial`/`skill` helpers are available, but `@ivars` and instance methods are not. Use `prompt_file` inside agents for full context.

---

## Development vs production

In **development**, prompt files are re-read on every call — edit the file and the change takes effect on the next request without a restart. Same lifecycle as view templates.

In **production**, prompt files are memoized on first read — static at deploy time.

---

## Missing file

If a prompt file doesn't exist at the expected path, ActiveAI raises `ActiveAI::PromptResolver::PromptNotFound` (a subclass of `ActiveAI::MissingPromptError`) with the expected path in the message. Because the hierarchy is `PromptNotFound < MissingPromptError < ActiveAI::Error`, a single `rescue ActiveAI::Error` clause catches it alongside other ActiveAI errors.
