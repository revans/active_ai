# Response

`agent.generate` returns an `ActiveAI::Response`: the same fields, in the same vocabulary, whichever provider answered.
`agent.complete` is unchanged and still returns the text as a String.

```ruby
response = SummaryAgent.new(message: "Summarize this.").generate

response.text               # the model's text. Possibly partial or empty: check finish_reason.
response.data               # the parsed Hash when the agent declares a response_schema, else nil
response.data_error         # why `data` is nil, for a finished answer that was not a JSON object
response.finish_reason      # :complete, :truncated, :tool_use, :refused or :other
response.raw_finish_reason  # the provider's own word: "stop", "length", "end_turn", "max_tokens", ...
response.refusal            # the model's stated reason, when finish_reason is :refused
response.provider           # :openai, :anthropic, ... who answered
response.model              # the model that actually served the request, as the provider reported it
response.requested_model    # the model that was asked for (an alias can resolve to a dated snapshot)
response.usage              # token counts, summed over every provider call in the run
response.turns              # how many provider calls the run took (more than 1 when tools ran)
response.request_id         # the provider's id for the final call, for support tickets
response.tool_calls         # tools the agent executed
response.latency            # seconds, wall clock, for the whole run
```

`response.complete?`, `truncated?`, `refused?` and `tool_use?` test `finish_reason`. `response.as_json` is plain
JSON-friendly data (symbols become strings), ready to store.

## A truncated or refused answer is a response, not an exception

The model did answer; what to do about it is the app's call. `ProviderError` is for failing to get an answer at all
(a bad key, a timeout, an unknown model).

```ruby
response = agent.generate
if response.truncated?
  # response.text is whatever arrived before the limit, and may be empty: reasoning models can spend the
  # whole limit on hidden thinking. response.usage[:reasoning_tokens] shows how much (OpenAI only).
elsif response.refused?
  show(response.refusal)
elsif response.data
  use(response.data)
else
  log(response.data_error)
end
```

`data` is parsed only for a finished answer. For a truncated or refused one it is nil and `data_error` is nil too,
because the finish reason is the explanation.

`complete_structured` is the shortcut that raises `StructuredOutputError` instead, with a specific message for each
case (cut off, declined, not a JSON object). Use `generate` when you want to handle them yourself.

## Usage

`usage` has the same keys for every provider: `input_tokens`, `output_tokens`, `cache_creation_tokens`,
`cache_read_tokens`, `reasoning_tokens`, `stop_reason` (raw) and `provider_request_id`.

- Counts are summed across the run's provider calls; `stop_reason` and `provider_request_id` come from the last one.
  `agent.last_usage` still reports only the final call.
- `reasoning_tokens` is reported by OpenAI and is nil for Anthropic, which folds thinking into `output_tokens`. Reasoning
  tokens count against the output limit, so a low limit can produce an empty, truncated answer.

See [providers.md](providers.md#finish-reasons) for how each provider's stop words map onto `finish_reason`.
