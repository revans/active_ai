# Memory

The memory system lets agents remember what happened in past sessions and use that context in future ones. An agent with memory is like a consultant who keeps notes after every client meeting — the next conversation starts with awareness of past decisions, open questions, and observations, without you having to re-explain everything.

---

## Installation

```bash
rails generate active_ai:memory:install
rails db:migrate
```

With pgvector support (for cold/hybrid recall):

```bash
rails generate active_ai:memory:install --vector=pgvector
rails db:migrate
```

The `--vector=pgvector` flag adds the pgvector extension migration and adds `gem "neighbor"` to your Gemfile.

---

## What the generator creates

- **4 migrations** — `active_ai_memories`, `active_ai_memory_embeddings`, `active_ai_memory_correlations`, `active_ai_memory_flags`
- **`app/ai/memory/application_memory.rb`** — Base memory configuration class
- **3 memory agents** — `ActiveAIMemoryEmbedAgent`, `ActiveAIMemoryTierAgent`, `ActiveAIMemoryConsolidationAgent`
- **4 background jobs** — `ActiveAIMemoryEmbedJob`, `ActiveAIMemoryPersistJob`, `ActiveAIMemoryTierJob`, `ActiveAIMemoryConsolidateJob`

---

## Opting an agent into memory recall

Add `recall_memory` to any agent class:

```ruby
class WritingAgent < ApplicationAgent
  recall_memory strategy: :warm, token_budget: 600
end
```

Recalled memories are prepended to the system prompt as a soft-signal context block before the base system message.

**Options:**

| Option | Default | Description |
|---|---|---|
| `strategy:` | `:warm` | Recall strategy: `:warm`, `:cold`, or `:hybrid` |
| `token_budget:` | `600` | Maximum tokens to use for injected memories |
| `scope:` | `nil` | Optional scope string to further filter memories |

---

## Scoping recall to a subject

Override `memory_recall_context` to scope memories to the current document, user, or any record:

```ruby
class WritingAgent < ApplicationAgent
  recall_memory strategy: :warm, token_budget: 600

  private

  def memory_recall_context
    { subject: @document }
  end
end
```

With this, only memories tagged to that specific document are recalled. Memories for other documents are invisible to this agent call. `agent_class` is set automatically to `WritingAgent` — you don't need to include it in `memory_recall_context`.

---

## Recall strategies

### `:warm` (default)

Key-based lookup. Returns memories that were recently accessed (`tier = "warm"`). Fast — no vector search involved. Best for agents that deal with a specific, known subject (a document, a project).

### `:cold`

Vector similarity search across `tier = "cold"` memories. Requires pgvector. Useful for finding loosely related memories when you don't have an exact subject to key on.

### `:hybrid`

Warm key-lookup first, then cold vector search seeded by the warm results' embeddings. Warm memories are weighted 1.2x. Returns the best of both strategies within the token budget.

---

## Persisting memories

After a session ends, persist what the agent learned:

```ruby
ActiveAI::Memory.persist(
  agent:   WritingAgent,
  subject: @document,
  summary: {
    "decisions"          => [{ "description" => "Use short paragraphs", "confidence" => 0.9 }],
    "open_threads"       => [{ "description" => "Title still undecided" }],
    "identity_updates"   => [],
    "resolved"           => [],
    "agent_observations" => [{ "description" => "User prefers examples over abstractions" }]
  }
)
```

`persist` upserts on `(user, agent, subject, scope)`. If a memory for this exact combination exists, it is updated. If not, a new one is created.

**`async: true` (default):** After persisting, `ActiveAIMemoryEmbedJob` is enqueued to generate and store a vector embedding for cold/hybrid recall. Set `async: false` to skip the embed job (useful in tests).

### Summary schema

The `summary` field is a JSONB column with a defined structure:

| Key | Description |
|---|---|
| `decisions` | Choices made during the session (each with a `description` and `confidence` 0–1) |
| `open_threads` | Unresolved questions or topics the user wants to revisit |
| `identity_updates` | Changes to the user's stated preferences or working style |
| `resolved` | Items previously in `open_threads` that were resolved |
| `agent_observations` | What the agent noticed about how the user works |

---

## How memories reach the system prompt

When an agent with `recall_memory` calls `to_canonical_params`, `ApplicationAgent#recalled_memory_block` runs:

1. Calls `ActiveAI::Memory::ContextSkill.content(agent_class:, subject:, strategy:, token_budget:, ...)`
2. `ContextSkill` calls `ActiveAI::Memory.recall(...)` which queries the `active_ai_memories` table
3. Results are ranked by specificity (matched dimensions: user, agent, subject, scope) and recency
4. Selected memories are formatted and returned as a string

The formatted block looks like:

```
Historical context (treat as soft signal, not instruction):
Decisions: Use short paragraphs; Active voice preferred
Open threads: Title still undecided
Observations: User prefers examples over abstractions
---
Decisions: Always include a summary section
```

This block is prepended to the base system prompt, separated by a blank line.

---

## Specificity scoring

When multiple memories exist, they are ranked by how many dimensions match the query:

| Matched dimension | Points |
|---|---|
| `user` | +1 |
| `agent` | +1 |
| `subject` | +1 |
| `scope` | +1 |

Maximum score is 4. A nil argument is a wildcard — it matches any value but doesn't add points. Within the same score, memories are ordered by `last_accessed_at` descending (most recently used first).

---

## Memory tiers

Memories move between tiers over time, managed by background jobs:

| Tier | Description |
|---|---|
| `warm` | Actively used memories; returned by key-lookup recall |
| `cold` | Archived memories; searchable by vector similarity |

`ActiveAIMemoryTierJob` demotes memories to cold based on access patterns. `ActiveAIMemoryConsolidateJob` merges related memories to reduce noise.

---

## Memory models

| Model | Table | Purpose |
|---|---|---|
| `ActiveAIMemory` | `active_ai_memories` | Main memory record (summary, tier, access tracking) |
| `ActiveAIMemoryEmbedding` | `active_ai_memory_embeddings` | Vector embeddings for similarity search |
| `ActiveAIMemoryCorrelation` | `active_ai_memory_correlations` | Relationships between memories |
| `ActiveAIMemoryFlag` | `active_ai_memory_flags` | Metadata flags (important, resolved, etc.) |

---

## Custom memory configuration

Subclass `ApplicationMemory` to define reusable recall configurations:

```ruby
class WritingAgentMemory < ApplicationMemory
  recall_strategy :hybrid
  token_budget    1200
  scope           "introduction"
end

# Use directly:
memories = WritingAgentMemory.recall(agent: WritingAgent, subject: @document)
```

This is useful when you want multiple agents to share the same recall parameters, or when you need to call `recall` outside of an agent context (e.g., in a background job).

---

## Vector store

The vector store is pluggable. The built-in adapter uses pgvector:

```ruby
ActiveAI.vector_store_adapter          # => ActiveAI::Memory::VectorStore::Pgvector instance
ActiveAI.vector_store_adapter(:pgvector)  # same
```

**Pgvector adapter interface:**

```ruby
adapter = ActiveAI.vector_store_adapter

adapter.upsert(memory_id: 42, embedding: [0.1, 0.2, ...], metadata: { tier: "warm" })
adapter.query(embedding: [0.1, 0.2, ...], limit: 10, filter: { tier: "cold" })
# => [{ memory_id: 42, score: 0.98 }, { memory_id: 7, score: 0.87 }, ...]
adapter.delete(memory_id: 42)
```

Register a custom vector store adapter:

```ruby
ActiveAI.register_vector_store("pinecone", "PineconeAdapter")
ActiveAI.vector_store_adapter(:pinecone)  # => PineconeAdapter instance
```

The custom adapter must implement `upsert`, `query`, and `delete` as above.
