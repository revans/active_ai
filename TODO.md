# TODO

## New Features to Discover

- **Agent job generator** — `rails generate active_ai:agent Writing` optionally generates a job stub alongside the agent (`app/jobs/writing_agent_job.rb`). Surfaces the job in the Rails app rather than hiding it inside the gem as a `run_later` method would. Gives developers the natural home for retry logic, queue assignment, and error handling. Raised 2026-06-24.

- **`output` format + `expect` eval DSL** — `output :json` (or `:yaml`, `:markdown`, `:string`) declares the response format; active_ai parses accordingly and `complete`/`run` returns the right type. Optional block adds format-agnostic validation via `expect`: `expect :title, type: :string` for JSON/YAML, `expect :h1, count: 1` for markdown, `expect :length, minimum: 100` for strings. Format and eval are visually distinct — format is the declaration line, eval lives in the block. Block is optional; `output :json` alone is valid. Eval mechanism differs per format under the hood but the DSL is consistent. Raised 2026-06-25.

## Deferred

_(nothing currently deferred)_
