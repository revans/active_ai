# Generators

ActiveAI ships a set of Rails generators for installation and scaffolding. Run any generator with `--help` to see its full option list.

---

## `active_ai:install`

Initial setup. Run this once when adding ActiveAI to an app.

```bash
rails generate active_ai:install
```

**Creates:**

| File | Description |
|---|---|
| `config/ai.yml` | Provider and model defaults per environment |
| `config/initializers/active_ai.rb` | Runtime configuration (API key resolver, search provider) |
| `app/ai/agents/application_agent.rb` | Base agent class for your app |
| `app/ai/tools/application_tool.rb` | Base tool class for your app |
| `app/ai/skills/application_skill.rb` | Base skill class for your app |
| `app/ai/workflows/application_workflow.rb` | Base workflow class for your app |
| `app/ai/orchestrators/application_orchestrator.rb` | Base orchestrator class for your app |

The generated `ApplicationAgent` includes `ActiveAI::Orchestratable` and `ActiveAI::Promptable`, sets up `provider_model_defaults`, and defines `build_messages` and `initialize`. Framework behavior (`build_params`, `skill_context`, history validation) lives in `ActiveAI::Agent::Base` and is inherited automatically.

---

## `active_ai:evaluation`

Scaffolds a provider-comparison harness, so every app answers "which model is better for my prompts?" the same way.

```bash
rails generate active_ai:evaluation
# creates app/ai/evaluation.rb and app/ai/evaluation/{cases.yml,case.rb,checks.rb,result.rb,comparison.rb,report.rb}
# creates lib/tasks/ai_evaluation.rake
# creates test/ai/evaluation/evaluation_test.rb

bin/rails ai:compare          # plan only: sends nothing
RUN=1 bin/rails ai:compare    # real calls (costs money); writes a blind transcript, a key, and results.json
```

The generated code is yours to change; re-running asks before overwriting a file you edited. The full guide, covering cases,
checks, options, reading the results, and customizing, is in **[evaluation.md](evaluation.md)**.

---

## `active_ai:agent`

Generates a new agent class.

```bash
rails generate active_ai:agent Writing
# creates app/ai/agents/writing_agent.rb
```

The generated agent inherits from `ApplicationAgent` and includes a commented example for prompt file loading.

---

## `active_ai:tool`

Generates a new tool class and its test file.

```bash
rails generate active_ai:tool PriceCheck
# creates app/ai/tools/price_check_tool.rb
# creates test/ai/tools/price_check_tool_test.rb
```

The generated tool includes stubs for `tool_name`, `description`, a commented `param` example, and `call`.

**Guard:** The generator refuses to create tools named `web_search` or `read_webpage` — those are the built-in tools. Use `ActiveAI::Tools::WebSearch` and `ActiveAI::Tools::WebPageReader` directly.

---

## `active_ai:prompt`

Generates a prompt file in the correct namespace directory.

```bash
rails generate active_ai:prompt agent writing
# creates app/ai/agents/prompts/writing.md.erb

rails generate active_ai:prompt skill tone_guidelines
# creates app/ai/skills/prompts/tone_guidelines.md.erb

rails generate active_ai:prompt orchestrator writing
# creates app/ai/orchestrators/prompts/writing.md.erb
```

**Valid namespaces:** `agent`, `skill`, `orchestrator`, `workflow`, `tool`, `memory`

The generator creates the directory if it doesn't exist and stubs the file with placeholder content. Files for the `skill` namespace include a note that they render without instance context — no `@ivars` or instance methods, since skill content is evaluated at class load time. All other namespaces (including `orchestrator`) generate a stub with instance-context hints.

---

## `active_ai:skill`

Generates a new skill class and its test file.

```bash
rails generate active_ai:skill Tone
# creates app/ai/skills/tone_skill.rb
# creates test/ai/skills/tone_skill_test.rb
```

The generated skill includes stubs for `skill_name` and `content`.

---

## `active_ai:workflow`

Generates a new workflow class and its test file.

```bash
rails generate active_ai:workflow ResearchAndDraft
# creates app/ai/workflows/research_and_draft_workflow.rb
# creates test/ai/workflows/research_and_draft_workflow_test.rb
```

The generated workflow includes a stub `run` method with a commented `step` example.

---

## `active_ai:orchestrator`

Generates a new orchestrator class and its test file.

```bash
rails generate active_ai:orchestrator Writing
# creates app/ai/orchestrators/writing_orchestrator.rb
# creates test/ai/orchestrators/writing_orchestrator_test.rb
```

The generated orchestrator inherits from `ApplicationOrchestrator` with commented examples for registering agents and workflows.

---

## `active_ai:memory:install`

Installs the full memory system.

```bash
# Without vector search
rails generate active_ai:memory:install

# With pgvector support
rails generate active_ai:memory:install --vector=pgvector
```

**Creates:**

| File | Description |
|---|---|
| `db/migrate/*_create_active_ai_memories.rb` | Main memory table |
| `db/migrate/*_create_active_ai_memory_embeddings.rb` | Vector embeddings table |
| `db/migrate/*_create_active_ai_memory_correlations.rb` | Memory relationships table |
| `db/migrate/*_create_active_ai_memory_flags.rb` | Metadata flags table |
| `app/ai/memory/application_memory.rb` | Memory configuration base class |
| `app/ai/agents/active_ai_memory_embed_agent.rb` | Agent that generates embeddings |
| `app/ai/agents/active_ai_memory_tier_agent.rb` | Agent that tiers memories warm/cold |
| `app/ai/agents/active_ai_memory_consolidation_agent.rb` | Agent that merges related memories |
| `app/jobs/active_ai_memory_embed_job.rb` | Enqueues embedding generation |
| `app/jobs/active_ai_memory_persist_job.rb` | Persists session memories |
| `app/jobs/active_ai_memory_tier_job.rb` | Runs the tier agent |
| `app/jobs/active_ai_memory_consolidate_job.rb` | Runs the consolidation agent |

**With `--vector=pgvector` also creates:**

| File | Description |
|---|---|
| `db/migrate/*_enable_pgvector.rb` | Enables the pgvector extension |
| `db/migrate/*_add_embedding_vector_to_memory_embeddings.rb` | Adds the vector column |

And adds `gem "neighbor"` to your Gemfile.

---

## `active_ai:credentials`

Installs the database-backed API key store.

```bash
rails generate active_ai:credentials
rails db:migrate
```

**Creates:**

- Migration for the `ai_credentials` table with encrypted `api_key` column and polymorphic `owner`

See [credentials.md](credentials.md) for how to use the credential store.

---

## `active_ai:event_log`

```bash
rails generate active_ai:event_log
rails generate active_ai:event_log --database=logs   # a database.yml entry other than primary
rails db:migrate
```

Stores every ActiveAI event as a row, so a run can be rebuilt from its prompts, answers, tool calls and queries. Creates:

| File | What it is |
|---|---|
| `db/migrate/..._create_active_ai_events.rb` | `active_ai_events`: name, `run_id`, `span_id`, `parent_span_id`, `request_id`, `job_id`, caller, start/finish times, duration, error, and the payload (`jsonb` on PostgreSQL) |
| `app/models/ai_event_record.rb` | Abstract class with its own connection pool to the same database, so events commit even when the app's transaction rolls back — a failed run is the one you want to read |
| `app/models/ai_event.rb` | `AiEvent`, including `ActiveAI::EventLog`: `AiEvent.for_run(run_id)`, `for_span`, `for_request`; override `filter_payload` to drop or redact keys |
| `config/initializers/active_ai_event_log.rb` | The subscriber: every `*.active_ai` event becomes a row; list events to skip at the top |

Recording never raises into the AI call: a failed insert is logged and dropped. The separate pool opens its own connections, so count it when sizing the database's connection limit. Payloads hold full prompts and answers — give the table the same retention and access rules as the data that goes into prompts.

See [instrumentation](instrumentation.md#tying-prompts-answers-and-logs-together) for the ids.

---

## After running generators

Always run `rails db:migrate` after any generator that creates migrations. Add the AI directory to your Zeitwerk configuration if you use nested namespacing — see the Zeitwerk collapse setup in `config/application.rb` generated by `active_ai:install`.
