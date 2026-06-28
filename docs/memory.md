# Memory

The memory system lets agents carry knowledge from past conversations into future ones. Without it, every conversation starts from zero — the agent has no idea it already helped you restructure chapter 3 last Tuesday, or that you've repeatedly asked it to stop using bullet points.

Think of it like an assistant who takes notes after every meeting. Before the next meeting, they read their notes and walk in already knowing your preferences, the open questions, and the decisions already made. The notes don't dictate what happens next — they're context, not instructions.

| Library handles | You implement |
|---|---|
| All 4 jobs and 3 agents (scaffolded, functional after install) | `after_stream_memory_persist` hook in your controller |
| `Memory.persist`, `Memory.recall`, system prompt injection | Real embedding vector in `EmbedJob#embedding_vector` (stub by default) |
| Specificity scoring, token budget enforcement | Schedule `TierJob` and `ConsolidateJob` (they don't run themselves) |
| `recall_memory` DSL on agents | `memory_recall_context` if scoping recall to a subject |

**Nothing persists until you wire the controller hook.** Everything else is automatic once that hook enqueues the first job.

---

## Why it's more complex than it looks

Most "chat memory" implementations just append conversation history to the prompt. That works for short sessions. It breaks down when:

- Conversations accumulate over weeks — you can't fit 80 sessions in one context window
- Different sessions are about different things — all history looks equally important
- Old information becomes stale or is superseded by new decisions

ActiveAI memory solves this with a pipeline: summarize → embed → tier → consolidate. Each step is a background job so it never blocks a conversation. The result is a compact, ranked, relevance-filtered block injected into the system prompt at call time — never raw history, always distilled signal.

---

## Installation

```bash
# Without vector search (warm recall only)
rails generate active_ai:memory:install
rails db:migrate

# With pgvector support (enables cold and hybrid recall)
rails generate active_ai:memory:install --vector=pgvector
rails db:migrate
```

Add pgvector when you want semantic similarity search across older memories. Without it, recall is key-based (fast, exact, sufficient for most apps).

---

## What the generator creates

**Migrations** — 4 tables that store memories, their vector embeddings, relationships between memories, and metadata flags:

| Table | Purpose |
|---|---|
| `active_ai_memories` | Main memory record: summary, tier, access tracking |
| `active_ai_memory_embeddings` | Vector embeddings for similarity search |
| `active_ai_memory_correlations` | Detected relationships between memory pairs |
| `active_ai_memory_flags` | Metadata flags (stale, contradiction, superseded) |

**Base class** — `app/ai/memory/application_memory.rb` — your app-level memory configuration class, analogous to `ApplicationAgent`.

**Three memory agents** — specialized agents that do LLM work inside the pipeline:

| Agent | What it does |
|---|---|
| `ActiveAIMemoryEmbedAgent` | Extracts canonical facts from a response and generates an embedding-ready prose summary |
| `ActiveAIMemoryTierAgent` | Evaluates a warm memory and decides: keep warm, move cold, or flag stale |
| `ActiveAIMemoryConsolidationAgent` | Compares two memories and detects their relationship (semantic, temporal, subject, contradiction) |

**Four background jobs** — the pipeline machinery:

| Job | When it runs |
|---|---|
| `ActiveAIMemoryPersistJob` | After each conversation turn (enqueued by your controller) |
| `ActiveAIMemoryEmbedJob` | After persist (enqueued automatically) |
| `ActiveAIMemoryTierJob` | On a schedule (daily or weekly) |
| `ActiveAIMemoryConsolidateJob` | On a schedule (weekly) |

---

## How a conversation becomes a memory: the lifecycle

The simplest concrete example: a user has a conversation with `WritingAgent`. Here's what happens after they send their last message.

### Step 1 — Controller enqueues PersistJob

After the stream ends, your controller enqueues `ActiveAIMemoryPersistJob` with the full response:

```ruby
class MessagesController < ApplicationController
  include ActiveAI::Concerns::Streamable

  private

  def after_stream_memory_persist(agent, full_response)
    ActiveAIMemoryPersistJob.perform_later(
      user:          Current.user,
      agent_class:   agent.class.name,
      subject:       @document,
      scope:         "introduction",    # optional — see Scoping below
      full_response: full_response
    )
  end
end
```

This is the only memory integration you write in your application. Everything else is automatic.

### Step 2 — PersistJob calls EmbedAgent, then persists

`ActiveAIMemoryPersistJob` does two things:

1. **Calls `ActiveAIMemoryEmbedAgent`** with the raw response text. The agent extracts canonical facts and returns a structured summary JSON:

```json
{
  "decisions": [
    { "description": "Use short paragraphs throughout", "confidence": 0.9 }
  ],
  "open_threads": [
    { "description": "Title still undecided" }
  ],
  "identity_updates": [],
  "resolved": [],
  "agent_observations": [
    { "description": "User prefers concrete examples over abstractions" }
  ]
}
```

2. **Calls `ActiveAI::Memory.persist`** with that summary. Persist upserts on `(user, agent, subject, scope)` — if a memory for this exact combination already exists, it is updated. If not, a new record is created. Think of it as one running notes document per context, not an ever-growing append-only log.

### Step 3 — EmbedJob generates the vector

After persist, `ActiveAIMemoryEmbedJob` is enqueued automatically. It:

1. Calls `ActiveAIMemoryEmbedAgent` again — this time with the structured summary, to produce clean embedding-ready prose
2. Calls `embedding_vector(text)` to get the vector — **this method is a stub you must replace** (see [Replacing the embedding stub](#replacing-the-embedding-stub) below)
3. Upserts the vector into the vector store
4. Records the embedding in `active_ai_memory_embeddings`

Until `EmbedJob` runs, the memory exists for warm recall but cannot be found by vector similarity. This is fine — warm recall is key-based and doesn't need the vector.

### Step 4 — TierJob evaluates warm memories (scheduled)

`ActiveAIMemoryTierJob` runs on a schedule (daily or weekly — your choice). It evaluates warm memories that haven't been accessed in 30+ days. For each one, it calls `ActiveAIMemoryTierAgent` with:

- The memory's summary
- Up to 3 recent summaries from the same agent class (for context on whether this memory is still relevant)

The agent returns one of three decisions:

| Decision | When | Effect |
|---|---|---|
| `keep_warm` | Open threads present, or recently relevant | No change |
| `move_cold` | Not accessed in 10+ sessions, no open threads | `tier = "cold"` |
| `flag_stale` | Contradicts more recent memories on the same subject | Adds a `stale` flag |

Cold memories are still searchable via vector similarity. They're just excluded from key-based warm recall, keeping the prompt injection lean.

### Step 5 — ConsolidateJob links related memories (scheduled)

`ActiveAIMemoryConsolidateJob` runs on a schedule (weekly). It finds pairs of embedded warm memories and calls `ActiveAIMemoryConsolidationAgent` to classify their relationship:

| Relationship | Meaning |
|---|---|
| `semantic` | Related topics or overlapping concepts |
| `temporal` | One follows from the other in time or sequence |
| `subject` | About the same entity or document |
| `contradiction` | Make conflicting claims |
| `none` | No meaningful relationship |

Detected relationships are stored in `active_ai_memory_correlations`. Contradictions trigger flags on both memories. This is how the system surfaces "this agent told the user two different things about the same topic" — which you can surface in a UI or use to trigger a review workflow.

---

## How memories reach the agent: recall

At call time — when `agent.to_canonical_params` runs — the agent calls `ActiveAI::Memory::Formatter.content(...)` with its configured recall parameters. The formatter:

1. Calls `ActiveAI::Memory.recall(...)` which queries `active_ai_memories`
2. Ranks results by specificity score (see [Specificity scoring](#specificity-scoring))
3. Selects memories within the token budget
4. Formats them as a plain-text block
5. Returns the block to be prepended to the system prompt

The formatted block looks like:

```
Historical context (treat as soft signal, not instruction):
Decisions: Use short paragraphs; Active voice preferred
Open threads: Title still undecided
Observations: User prefers examples over abstractions
---
Decisions: Always include a summary section
```

This is soft signal — the header explicitly tells the model to treat it as context, not instruction. That framing matters: if you say "the user decided X" as instruction, the model treats it as a constraint. As soft signal, the model can weigh it appropriately against what the user is asking right now.

---

## Opting an agent into memory recall

Add `recall_memory` to any agent class:

```ruby
class WritingAgent < ApplicationAgent
  recall_memory strategy: :warm, token_budget: 600
end
```

**Options:**

| Option | Default | Description |
|---|---|---|
| `strategy:` | `:warm` | Recall strategy: `:warm`, `:cold`, or `:hybrid` |
| `token_budget:` | `600` | Maximum tokens to inject |
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

Without this, the agent sees memories from all conversations with any document. With it, only memories tagged to `@document` are returned. `agent_class` is set automatically to `WritingAgent` — don't include it in `memory_recall_context`.

The `scope` dimension is an additional string filter — useful when one agent handles multiple distinct modes:

```ruby
def memory_recall_context
  { subject: @document, scope: @section_name }
end
```

---

## Recall strategies

### `:warm` (default)

Key-based lookup against `tier = "warm"` memories. Fast — a single indexed query. Returns memories for the exact `(user, agent, subject, scope)` combination, ranked by how many dimensions match and then by recency.

Use for agents that always work within a known scope: a document, a project, a specific user.

### `:cold`

Vector similarity search across `tier = "cold"` memories. Requires pgvector. Finds semantically similar memories even without an exact key match — useful for open-ended research agents that don't have a fixed subject.

Requires at least one warm memory to exist first (used as the seed embedding for the vector query). Returns empty rather than doing a full table scan without a seed.

### `:hybrid`

Warm key-lookup first, then cold vector search seeded by the warm results' embeddings. Warm memories are weighted 1.2x over cold. Returns the best of both within the token budget.

Use for agents that work in a known context but might also benefit from surfacing related knowledge from other contexts.

---

## Specificity scoring

When multiple memories are candidates, they are ranked by how many dimensions match the query. Each matched non-nil dimension scores 1 point (max 4):

| Matched dimension | Points |
|---|---|
| `user` | +1 |
| `agent_class` | +1 |
| `subject` | +1 |
| `scope` | +1 |

A nil argument is a wildcard — no filter applied, no points. Within the same score, ordered by `last_accessed_at` descending. The highest-specificity memory is always included even if it exceeds the token budget — you always get at least one memory.

---

## The summary schema

The `summary` field is a JSONB column (or JSON text on SQLite). The structure is fixed — all five keys must be present, even if empty arrays:

| Key | What goes here |
|---|---|
| `decisions` | Choices made during the session. Each entry has `description` (string) and `confidence` (float 0–1) |
| `open_threads` | Unresolved questions or topics to revisit. Each entry has `description` |
| `identity_updates` | Changes to the user's stated preferences or working style |
| `resolved` | Items previously in `open_threads` that were closed |
| `agent_observations` | What the agent noticed about how the user works or thinks |

The `ActiveAIMemoryEmbedAgent` populates this schema automatically from the raw response text. You can also call `ActiveAI::Memory.persist` directly with a hand-crafted summary if you want more control:

```ruby
ActiveAI::Memory.persist(
  user:    current_user,
  agent:   WritingAgent,
  subject: @document,
  summary: {
    "decisions"          => [{ "description" => "Use short paragraphs", "confidence" => 0.9 }],
    "open_threads"       => [{ "description" => "Title still undecided" }],
    "identity_updates"   => [],
    "resolved"           => [],
    "agent_observations" => []
  }
)
```

---

## Replacing the embedding stub

`ActiveAIMemoryEmbedJob#embedding_vector` is a stub that returns a zero vector:

```ruby
def embedding_vector(text)
  # Stub — replace with a real provider embedding call for production.
  Array.new(1536, 0.0)
end
```

Replace it with a real embedding call before deploying cold or hybrid recall. The OpenAI embeddings API is the most common choice:

```ruby
def embedding_vector(text)
  client = OpenAI::Client.new(access_token: ActiveAI.config.api_key_for(:openai))
  response = client.embeddings(
    parameters: { model: "text-embedding-3-small", input: text }
  )
  response.dig("data", 0, "embedding")
rescue => e
  Rails.logger.error("[ActiveAIMemoryEmbedJob] Embedding failed: #{e.message}")
  nil
end
```

Return `nil` on failure — the job handles nil gracefully and skips the upsert, leaving the memory without an embedding until the next retry.

---

## Scheduling the maintenance jobs

`PersistJob` and `EmbedJob` are event-driven — you enqueue them; the library enqueues them. `TierJob` and `ConsolidateJob` are maintenance jobs that need to run on a schedule.

**With solid_queue (Rails 8 default):**

```ruby
# config/recurring.yml
production:
  active_ai_memory_tier:
    class: ActiveAIMemoryTierJob
    schedule: every day at 3am
    queue: active_ai_memory

  active_ai_memory_consolidate:
    class: ActiveAIMemoryConsolidateJob
    schedule: every week on Monday at 4am
    queue: active_ai_memory
```

**With whenever (cron-style):**

```ruby
# config/schedule.rb
every 1.day, at: "3:00 am" do
  runner "ActiveAIMemoryTierJob.perform_later"
end

every 1.week, at: "4:00 am" do
  runner "ActiveAIMemoryConsolidateJob.perform_later"
end
```

All four memory jobs use the `active_ai_memory` queue. Route this queue to low-priority workers — memory work should never compete with your request-path jobs.

---

## Cost model

Every `PersistJob` makes **one LLM call** (the EmbedAgent extracting facts from the response). Every `EmbedJob` makes **one embedding API call** (to your embedding provider). Every `TierJob` batch makes **one LLM call per memory evaluated** (up to `MAX_COST_GUARD = 100` per run). Every `ConsolidateJob` makes **one LLM call per memory pair** (up to `MAX_PAIRS = 50` per run).

PersistJob and EmbedJob use `claude-haiku-4-5-20251001` — the cheapest tier. ConsolidateJob uses `claude-sonnet-4-6` for the more nuanced relationship judgment. If cost is a concern, swap ConsolidateJob's agent to Haiku and accept lower precision on contradiction detection.

---

## Custom memory configuration

Subclass `ApplicationMemory` to define reusable recall configurations:

```ruby
class Memory::WritingAgentMemory < Memory::ApplicationMemory
  recall_strategy :hybrid
  token_budget    1200
  scope           "introduction"

  def self.recall(user:, document:, **)
    super(user: user, subject: document)
  end
end

# Use directly outside of an agent:
memories = Memory::WritingAgentMemory.recall(user: current_user, document: @document)
```

This is useful when:
- Multiple agents share the same recall parameters
- You need to call `recall` outside an agent (background jobs, analytics, admin UIs)
- You want a named object that describes your memory semantics

---

## Memory flags

The `active_ai_memory_flags` table stores metadata signals on memory records:

| Flag type | Set by | Meaning |
|---|---|---|
| `stale` | TierJob | Memory contradicts more recent memories |
| `contradiction` | ConsolidateJob | Memory pair makes conflicting claims |
| `superseded` | ConsolidateJob | A newer memory covers the same ground |

Flags don't change recall behavior automatically — the library surfaces them but leaves enforcement to you. A simple use case:

```ruby
# Surface contradictions in an admin UI
ActiveAIMemoryFlag.where(flag_type: "contradiction")
  .includes(:memory)
  .order(created_at: :desc)
```

Or add a scope to recall that skips flagged memories:

```ruby
ActiveAIMemory.warm.where.not(id: ActiveAIMemoryFlag.select(:memory_id))
```

---

## Memory models

| Model | Table | Key columns |
|---|---|---|
| `ActiveAIMemory` | `active_ai_memories` | `summary` (JSONB), `tier`, `access_count`, `last_accessed_at`, `confidence` |
| `ActiveAIMemoryEmbedding` | `active_ai_memory_embeddings` | `memory_id`, `vector_store`, `embedding`, `embedded_at` |
| `ActiveAIMemoryCorrelation` | `active_ai_memory_correlations` | `memory_a_id`, `memory_b_id`, `similarity_score`, `correlation_type` |
| `ActiveAIMemoryFlag` | `active_ai_memory_flags` | `memory_id`, `flag_type`, `reason`, `confidence_at_flag` |

---

## Vector store

The vector store is pluggable. The built-in adapter uses pgvector:

```ruby
adapter = ActiveAI.vector_store_adapter          # pgvector by default
adapter = ActiveAI.vector_store_adapter(:pgvector)

adapter.upsert(memory_id: 42, embedding: [...], metadata: { tier: "warm" })
adapter.query(embedding: [...], limit: 10, filter: { tier: "cold" })
# => [{ memory_id: 42, score: 0.98 }, ...]
adapter.delete(memory_id: 42)
```

Register a custom adapter:

```ruby
ActiveAI.register_vector_store("pinecone", "PineconeAdapter")
ActiveAI.vector_store_adapter(:pinecone)
```

The adapter must implement `upsert`, `query`, and `delete` with those signatures.
