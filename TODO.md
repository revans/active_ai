# TODO

## New Features to Discover

- **Agent job generator** — `rails generate active_ai:agent Writing` optionally generates a job stub alongside the agent (`app/jobs/writing_agent_job.rb`). Surfaces the job in the Rails app rather than hiding it inside the gem as a `run_later` method would. Gives developers the natural home for retry logic, queue assignment, and error handling. Raised 2026-06-24.

- **`output` format + `expect` eval DSL** — `output :json` (or `:yaml`, `:markdown`, `:string`) declares the response format; active_ai parses accordingly and `complete`/`run` returns the right type. Optional block adds format-agnostic validation via `expect`: `expect :title, type: :string` for JSON/YAML, `expect :h1, count: 1` for markdown, `expect :length, minimum: 100` for strings. Format and eval are visually distinct — format is the declaration line, eval lives in the block. Block is optional; `output :json` alone is valid. Eval mechanism differs per format under the hood but the DSL is consistent. Raised 2026-06-25.

## Raised by Atlas F-066 (2026-10-28)

What got in the way of the agents that built Atlas's first ActiveAI feature (the architect, designer and engineer
reports in Atlas `docs/briefs/066-ai-data-querying/`). Already fixed then: RecordQuery's missing count past the row
cap (`total`), generated class names under the "AI" acronym, omakase style in generated code, and the memory and
credentials generators crashing.

- **A cut-off stream looks like a finished answer.** `stream_agent` calls `after_stream` with the partial text and no
  sign the client disconnected (or the stream stopped early), so an app saves half an answer as complete. Pass a
  `completed:`/`interrupted:` flag (or a small result object) to `after_stream`. Also unblocks a "Stop" button: an app
  cannot offer one without knowing the stream ended early. Raised by the architect and the designer.

- **RecordQuery reads rows, not answers.** One root, rows only, capped: no counts by group, sums or comparisons across
  roots. Atlas cut its Finance agent (margin is computed, not read) and its agency-wide agent (comparing a 30-customer
  book is 30+ tool calls with nothing to add them up) from v1 because of it. Idea: an aggregate tool whose allowed
  aggregates are declared like scopes (`ai_readable aggregates: { count_by: [:status, :marketplace], sum: [:total_cents] }`),
  still read-only, still root-bound, never raw SQL, and a root set the model can fan out over for rollups.

- **Count-shaped questions are slow on big tables.** Answering "how many orders are in status X" means reading rows
  through the scopes; at 1M order snapshots for one Atlas customer, all-time status questions passed the 5 s timeout
  (about 8 s) while dated ones took under 1 s. The aggregate tool above would answer counts with one `COUNT`/`GROUP BY`;
  until then, consider a per-association timeout and a scope description hint that steers the model to date ranges.

- **The "AI" acronym surprises apps.** The railtie registers `acronym "AI"` for every app, so an app's own classes must
  be spelled `AIConversation`, not `AiConversation`. Atlas's engineer first met it as an unexplained migration
  `NameError` and renamed its own classes before tracing it to the gem. Say it up front in the README and the install
  generator's output, and decide whether an app can opt out.

- **RecordQuery's database-level guards depend on how it is called.** The READ ONLY transaction and the statement
  timeout apply only when no transaction is open; called inside an app transaction, only `while_preventing_writes`
  and the declared-scope allowlist protect it (Atlas F-066 security review; unreachable in Atlas today). Use a
  savepoint with `SET LOCAL statement_timeout` and `SET TRANSACTION READ ONLY` where PostgreSQL allows it, or raise
  when called inside a transaction, so the guarantee does not depend on the caller.

- **Prune hypertables by dropping chunks.** With `--timescaledb`, `AIEvent.prune` still deletes rows in batches;
  `drop_chunks` (or a TimescaleDB retention policy) removes whole days almost for free and leaves no bloat. Have the
  generated prune job use it when the table is a hypertable (Atlas F-066 performance review).

- **Hard to know what a generator will produce without running it.** Atlas's architect could not run the event-log
  generator, so it designed the TimescaleDB changes from reading templates. Document each generator's output with its
  options (a rendered example per option set in `docs/generators.md`), so a plan can be checked against the real output.

## Deferred

_(nothing currently deferred)_
