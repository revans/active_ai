# Evaluating providers and models

`rails generate active_ai:evaluation` scaffolds a small harness into your app that answers one question the same way
everywhere: **which provider and model is better for *my* prompts?**

You describe a few scenarios, it runs each one through every provider several times, scores what came back with
checks you control, and writes a transcript you can read without knowing which model wrote what.

It is a different job from the gem's own live contract tests (`rake test:live`). Those check that the *library* talks
to each provider correctly. This checks how well each model handles *your* prompts.

---

## Quick start

```bash
rails generate active_ai:evaluation
```

1. **Edit `app/ai/evaluation/cases.yml`.** Replace the starter case with real scenarios (see [Cases](#cases)).
2. **Plan it.** Nothing is sent:
   ```bash
   bin/rails ai:compare
   ```
   ```
   AI provider comparison (plan only, nothing sent)
     providers: openai (gpt-5.6-terra, key found), anthropic (claude-sonnet-5-5, key found)
     cases:     smoke_test
     runs:      2 per case per provider
     calls:     4 real API calls

   Nothing was sent. Re-run with RUN=1 to make these calls.
   ```
3. **Run it.** This makes real calls and costs money:
   ```bash
   RUN=1 bin/rails ai:compare
   ```
4. **Read `report.md` first**, the blind transcript, then open `key.json` to see who was who
   ([Reading the results](#reading-the-results)).

The plan is the default on purpose. It lists the providers, models, cases, and the exact number of calls, and flags any
provider whose key is missing. `RUN=1` refuses to start if a key is missing, and tells you where to add it.

---

## What gets generated

| File | Purpose |
|---|---|
| `app/ai/evaluation.rb` | The `Evaluation` namespace and the default `PROVIDERS` list. |
| `app/ai/evaluation/cases.yml` | **Your scenarios.** The part you edit most. |
| `app/ai/evaluation/case.rb` | Asks one provider to answer one scenario. Override `build_agent` for agents that need more than a message. |
| `app/ai/evaluation/checks.rb` | The checks a case can name. Generic ones are included; add your own. |
| `app/ai/evaluation/result.rb` | What one provider did on one case, and how it scored. |
| `app/ai/evaluation/comparison.rb` | The plan, and the loop over providers x cases x runs. |
| `app/ai/evaluation/report.rb` | The scorecard and the blind transcript. |
| `lib/tasks/ai_evaluation.rake` | `bin/rails ai:compare`. |
| `test/ai/evaluation/evaluation_test.rb` | Keeps the harness honest without calling any provider. |

The generated code is **yours to change**. Re-running the generator asks before overwriting a file you edited.

---

## Cases

Each case says which agent answers which message, and which checks the answer must pass:

```yaml
- id: refund_policy
  title: Explains the refund policy without inventing terms
  agent: SupportAgent
  message: "Can I get a refund after 45 days?"
  checks:
    - finished
    - { max_seconds: { seconds: 15 } }
    - { contains: { text: "30 days" } }
    - { excludes: { text: "guarantee" } }
```

| Key | Meaning |
|---|---|
| `id` | A short unique name. Used by `CASES=` and in the reports. |
| `title` | A human description. Shown in the blind transcript. |
| `agent` | The name of an agent class in your app. |
| `message` | What is sent. By default the agent is built as `Agent.new(message:, provider:, model:)`. |
| `checks` | What a good answer must pass. A bare name, or `{ name: { parameter: value } }`. |

Use real scenarios. A good set mixes ordinary cases, awkward ones, and the failures you would hate to ship.

> **Cases are sent to the providers.** Don't put real customer data in `cases.yml`; write synthetic scenarios.

---

## Checks

Each `check_*` method in `Evaluation::Checks` returns an outcome: whether it passed, and what it found. A case names
checks without the `check_` prefix.

| Check | Parameters | Passes when |
|---|---|---|
| `finished` | none | The model finished: not cut off at the token limit, not refused (`finish_reason` is `:complete`). |
| `structured` | none | The agent's `response_schema` produced an object (`response.data` is present). |
| `max_seconds` | `seconds:` | The whole call took at most this long. |
| `max_output_tokens` | `tokens:` | The answer used at most this many output tokens. |
| `contains` | `text:` | The answer includes the text, ignoring case. |
| `excludes` | `text:` | The answer does not include the text, ignoring case. |
| `matches` | `pattern:` | The answer matches the regular expression (case-insensitive). |

### Writing your own

Add a method to `app/ai/evaluation/checks.rb`. It can read the response and returns an outcome:

```ruby
def check_no_apology
  found = response.text.to_s[/\b(sorry|apologi[sz]e)\b/i]
  outcome found.nil?, found ? "apologised: #{found.inspect}" : "no apology"
end
```

Then use it in a case: `- no_apology`. `response` is the [`ActiveAI::Response`](response.md), so `finish_reason`,
`data`, `usage`, `refusal`, and the served `model` are all available.

Checks that use word lists are heuristics at best. A pass means "nothing obviously wrong", never "good".

---

## Options

All optional, and all environment variables:

| Variable | Default | Effect |
|---|---|---|
| `RUN=1` | off | Make the real calls. Without it, only the plan is printed. |
| `RUNS=4` | `2` | Times each case runs per provider. More runs smooth out variation. |
| `CASES=a,b` | all | Run only these case ids. |
| `PROVIDERS=openai` | `openai,anthropic` | Limit to some providers. |
| `OPENAI_MODEL=...` | the provider default | Compare a specific model. `ANTHROPIC_MODEL=...` likewise. |

The default models come from `ApplicationAgent::PROVIDER_MODEL_DEFAULTS` in your app. To compare, say, a cheap and a
flagship model of the same provider, run it twice with a different `*_MODEL` each time.

```bash
RUN=1 RUNS=4 CASES=refund_policy PROVIDERS=openai OPENAI_MODEL=gpt-5.6-luna bin/rails ai:compare
```

---

## Reading the results

Each run writes a directory, `tmp/ai_comparison/<timestamp>/`, with three files:

| File | What it is |
|---|---|
| `report.md` | **Read this first.** A blind transcript: every case with each answer labelled *Model A* or *Model B*. |
| `key.json` | Which letter is which provider. Open it only after you have read `report.md`. |
| `results.json` | Everything, unblinded: every answer, every check outcome, tokens, seconds, finish reason, served model. |

The terminal prints a scorecard:

```
                       openai         anthropic
  checks passed        94/96 (98%)    91/96 (95%)
  no answer at all     0              0
  cut off (truncated)  0              1
  median seconds       2.1            6.2
  tokens in / out      12074 / 3891   18699 / 14606
```

### How to judge it

- **Read the blind transcript before the key.** Ask of each answer whether it is right, useful, and what you would want
  to ship. Checks can't judge tone or usefulness; you can.
- **A gap of a few checks is noise.** Samples are small. Add `RUNS=4` or more if the result is close.
- **Read every failure and decide whether the check was fair.** Early on, many "failures" are the check being wrong. For
  example, a promise check flagged *"I can't say it'll be fine"* because it matched the words and missed the refusal. Fix
  the check, then compare. Do this for both providers; scrutinise the side you favour just as hard.
- **Passes can be wrong too.** A check only catches what it looks for. Skim the answers that passed.
- **Truncation shows up.** "Cut off" counts answers that hit the token limit. On reasoning models the limit can be spent
  on hidden thinking, leaving an empty answer, which is a real finding, not noise. Compare providers at the limits you
  will actually ship: an agent's [`max_tokens`](agents.md#max_tokens) can suit one provider and truncate another.

---

## Customizing

### Agents that need more than a message

`Case#build_agent` builds the agent from the case's `message`. Override it when your agents need a record, a user, or
conversation history:

```ruby
# app/ai/evaluation/case.rb
def build_agent(provider, model)
  user = User.find_by!(email: "evaluation@example.com")
  agent.constantize.new(user: user, message: message, provider: provider.to_sym, model: model)
end
```

### Agents that write to the database

If answering a case creates records, wrap the call so a comparison leaves nothing behind:

```ruby
# app/ai/evaluation/case.rb
def ask(provider:, model: nil)
  result = nil
  ActiveRecord::Base.transaction do
    result = Evaluation::Result.new(evaluation_case: self, provider: provider, response: build_agent(provider, model).generate)
    raise ActiveRecord::Rollback
  end
  result
rescue ActiveAI::Error, Timeout::Error => failure
  Evaluation::Result.new(evaluation_case: self, provider: provider, failure: failure)
end
```

### Provider failures

A bad key, an outage, or an unknown model does not stop the run. `Case#ask` turns it into a result with the failure
attached, every check counts as failed, and the scorecard shows it under "no answer at all". The reason is in
`results.json`.

---

## Testing the harness

The generated `test/ai/evaluation/evaluation_test.rb` makes no provider calls. It checks that every case names an agent
and checks that exist, that planning sends nothing, and that the generic checks pass a good answer and catch a cut-off
one. It uses [`build_ai_response`](testing.md#response-assertions), so extend it the same way when you add checks:

```ruby
test "no_apology catches an apology" do
  result = Evaluation::Result.new(evaluation_case: a_case, provider: "openai", response: build_ai_response(text: "Sorry about that."))
  assert_not result.check_no_apology.passed
end
```

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| `key MISSING` in the plan, or "Not running: no API key" | Add `active_ai.<provider>_api_key` with `bin/rails credentials:edit`, or limit `PROVIDERS=`. |
| `uninitialized constant ApplicationAgent::PROVIDER_MODEL_DEFAULTS` | The plan reads default models from there. Run `rails generate active_ai:install`, or edit `Comparison#models`. |
| `wrong number of arguments` building an agent | Your agent's constructor differs. Override `Case#build_agent`. |
| `model ... does not exist` for a provider | That provider's account doesn't have the model. Set `OPENAI_MODEL` / `ANTHROPIC_MODEL`. Provider errors report the provider's own explanation. |
| A case always fails every check | The provider call failed. Look at `failure` for that result in `results.json`. |

See also: [Response](response.md) (what a check sees), [Testing](testing.md), [Generators](generators.md).
