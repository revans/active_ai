# Skills

Skills are behavioral instruction blocks. They tell the model *how* to behave — tone, structure, citation style, output format — rather than providing data or executing actions. They are distinct from tools (which do things) and memory (which supplies context).

Think of a skill like a standing order to an employee: "Always send replies in plain English, no bullet points." The order sits at the top of every conversation without the employee needing to be reminded each time.

---

## Defining a skill

Inherit from `ApplicationSkill` (which inherits from `ActiveAI::Skill::Base`):

```ruby
class ActiveVoiceSkill < ApplicationSkill
  skill_name "active_voice"
  content "Write in active voice. Avoid passive constructions."
end
```

**Required DSL declarations:**

| DSL | Description |
|---|---|
| `skill_name "..."` | Unique identifier for this skill |
| `content "..."` | The instruction text sent to the model (static skills) |

---

## Dynamic skills

`content` can accept keyword arguments for context-sensitive instructions:

```ruby
class ToneSkill < ApplicationSkill
  skill_name "tone"

  def self.content(message: nil, context: nil, **)
    if context.to_s.include?("formal")
      "Use a formal, professional tone throughout."
    else
      "Use a conversational, approachable tone."
    end
  end
end
```

When the agent calls `to_definition(skill_context)`, ActiveAI checks whether `content` accepts kwargs. If it does, it calls `content(**context)`. If it doesn't (passive skill), it calls `content` with no arguments.

The skill context is `{ message: @message, context: @context }` — the agent's current message and document context.

---

## Registering skills on an agent

Three ways to register skills — all can be combined on the same agent:

```ruby
class WritingAgent < ApplicationAgent
  # Single skill class
  skills ToneSkill

  # Array of skill classes
  skills [BlogStructureSkill, CitationStyleSkill]

  # Inline string — works like an anonymous skill
  skills "Prefer active voice over passive voice."
  skills "Never use the word 'utilize'."
end
```

Skills accumulate — each `skills` call appends to the list. A subclass inherits its parent's skills and can add more.

---

## Per-call skills

Pass skill instances directly when creating an agent for runtime-configured instructions:

```ruby
custom_skill = OpenStruct.new(id: "tone", name: "tone", content: current_user.preferred_tone)

WritingAgent.new(
  message: "Write a summary.",
  skills:  [custom_skill]
)
```

Per-call skills are merged with class-level skills. The model receives all of them.

---

## How skills reach the model

Each skill becomes a separate system block in the provider request. On Anthropic, each block gets its own cache control marker — so a skill that rarely changes (structure guidelines) can be cached independently from one that changes per-request (tone from user preferences).

This is why skills are separate from the system prompt: they allow granular caching that a single merged system string cannot.

---

## Skills vs memory

| | Skills | Memory |
|---|---|---|
| Purpose | Behavioral instructions | Historical context |
| Changes? | Rarely (deploy-time) | Every session |
| Declared? | Class-level DSL | `recall_memory` DSL |
| Cached? | Yes, per-block | No |
| Signal weight | Instruction | Soft signal |

Memory is prepended to the system prompt as a "soft signal, not instruction" block. Skills are active behavioral directives. Keep them separate.
