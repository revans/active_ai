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
response.latency            # seconds the whole run took, measured with a monotonic clock
response.start_time         # when the run started: UTC, to the millisecond, set by ActiveAI
response.end_time           # when the run ended: UTC, to the millisecond
```

`response.complete?`, `truncated?`, `refused?` and `tool_use?` test `finish_reason`. `response.as_json` is plain
JSON-friendly data (symbols become strings), ready to store.

## What to expect back

Every provider returns the **same JSON shape**. Only some values differ. This is `response.as_json`: keys are strings,
symbols become strings, and it is ready to store or log. (In Ruby, `response.finish_reason` is a Symbol and
`response.provider` is a Symbol; `as_json` turns them into strings.)

```json
{
  "text": "",                  // String. What the model wrote. May be "" or partial: check finish_reason.
  "data": null,                // Object or null. The parsed structured answer (needs a response_schema).
  "data_error": null,          // String or null. Why `data` is null for a finished answer.
  "provider": "openai",        // "openai", "anthropic", "xai", or your custom provider's name.
  "requested_model": "...",    // String. The model you asked for.
  "model": "...",              // String or null. The model that served it, as the provider reported it.
  "finish_reason": "complete", // "complete" | "truncated" | "tool_use" | "refused" | "other".
  "raw_finish_reason": "stop", // String or null. The provider's own word, never altered.
  "refusal": null,             // String or null. The model's stated reason, when finish_reason is "refused".
  "usage": { },                // Object or null. Token counts (below), summed over the whole run.
  "turns": 1,                  // Integer. Provider calls the run took (more than 1 when tools ran).
  "request_id": "...",         // String or null. The provider's id for the final call.
  "tool_calls": [ ],           // Array. Tools the agent executed: { id, name, result }.
  "latency": 1.045,            // Number. Seconds the whole run took (monotonic clock).
  "start_time": "2026-10-22T19:40:57.278Z", // String. When the run started: ISO 8601, UTC, always 3 millisecond digits.
  "end_time": "2026-10-22T19:40:58.323Z"    // String. When the run ended, same format.
}
```

### Field reference

| Field | Type | Can be null? | Notes |
|---|---|---|---|
| `text` | string | no (may be `""`) | Empty when the answer was cut off before any text, or refused. |
| `data` | object | **yes** | Set only for a *finished* answer when the agent declares a `response_schema`. |
| `data_error` | string | **yes** | Set only when the answer finished but was not a JSON object. `data` and `data_error` are never both set. |
| `provider` | string | no | Who answered. |
| `requested_model` | string | no | What you asked for. |
| `model` | string | **yes** | What actually served it. Null only for a custom provider that does not report it. |
| `finish_reason` | string | no | One of five values. See [providers.md](providers.md#finish-reasons) for each provider's mapping. |
| `raw_finish_reason` | string | **yes** | Always a String when present, even where the provider's SDK uses symbols. |
| `refusal` | string | **yes** | Only when `finish_reason` is `"refused"` and the provider said why. |
| `usage` | object | **yes** | Null if the provider reported nothing. |
| `turns` | integer | no | `0` only when no provider call happened (a stubbed agent). |
| `request_id` | string | **yes** | Equals `usage.provider_request_id`. |
| `tool_calls` | array | no (may be `[]`) | Each entry is `{ "id", "name", "result" }`: the tool's *result*, not its input. |
| `latency` | number | no | Seconds the run took, rounded to milliseconds. Measured with a monotonic clock. |
| `start_time` | string | no | When the run started. ISO 8601 UTC with exactly three fractional digits, e.g. `2026-10-22T19:40:57.278Z`. |
| `end_time` | string | no | When the run ended, same format. |

`start_time` and `end_time` are set by ActiveAI itself (wall clock, UTC, rounded to the millisecond), not reported by the
provider, and the format does not depend on any JSON time-precision setting in your app. In Ruby they are `Time` objects;
`as_json` renders them as strings, and `Time.iso8601(...)` parses them back to the same instant. `latency` is measured with
a monotonic clock, so it stays correct if the system clock is adjusted mid-run; it can differ from `end_time - start_time`
by a few milliseconds. Use the times for "when did this happen" and `latency` for "how long did it take".

### `usage`

The same keys for every provider:

| Key | Type | Notes |
|---|---|---|
| `input_tokens` | integer | |
| `output_tokens` | integer | Includes hidden reasoning tokens. A low limit can be spent entirely on thinking. |
| `cache_creation_tokens` | integer | OpenAI always reports `0` (it caches automatically and does not report creation). |
| `cache_read_tokens` | integer | Tokens served from the provider's prompt cache. |
| `reasoning_tokens` | integer or null | **OpenAI reports it; Anthropic is `null`** (it folds thinking into `output_tokens`). |
| `stop_reason` | string | The provider's raw word again, kept here for back-compatibility. |
| `provider_request_id` | string | |

Counts are summed over every provider call in the run. `stop_reason` and `provider_request_id` come from the final call.

### Same shape, different values

| | OpenAI | Anthropic |
|---|---|---|
| `raw_finish_reason` | `stop`, `length`, `tool_calls`, `content_filter` | `end_turn`, `max_tokens`, `tool_use`, `refusal`, `stop_sequence` |
| `request_id` looks like | `chatcmpl-...` | `msg_...` |
| `usage.reasoning_tokens` | an integer (can be `0`) | `null` |
| `usage.cache_creation_tokens` | always `0` | real count when caching is on |
| A refusal arrives as | a `refusal` field in structured mode, or `content_filter` | a `refusal` stop reason, with no text |
| `data` for a schema | strictly enforced by the provider | guided by the provider; still validate it |
| `model` | the served model id | the served model id |

xAI uses OpenAI's shapes and mapping. It is not covered by the live contract tests.

### Real examples

Captured from real calls on 2026-10-22 (`gpt-5.6-terra` and `claude-sonnet-5-5`); request ids replaced with placeholders.
Latency and token counts vary run to run.

**A plain answer**

<details>
<summary>OpenAI</summary>

```json
{
  "text": "ok",
  "data": null,
  "data_error": null,
  "provider": "openai",
  "requested_model": "gpt-5.6-terra",
  "model": "gpt-5.6-terra",
  "finish_reason": "complete",
  "raw_finish_reason": "stop",
  "refusal": null,
  "usage": {
    "input_tokens": 18,
    "output_tokens": 4,
    "cache_creation_tokens": 0,
    "cache_read_tokens": 0,
    "reasoning_tokens": 0,
    "stop_reason": "stop",
    "provider_request_id": "chatcmpl-XXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
  },
  "turns": 1,
  "request_id": "chatcmpl-XXXXXXXXXXXXXXXXXXXXXXXXXXXXX",
  "tool_calls": [],
  "latency": 1.602,
  "start_time": "2026-10-22T19:40:57.278Z",
  "end_time": "2026-10-22T19:40:58.879Z"
}
```

</details>

<details>
<summary>Anthropic</summary>

```json
{
  "text": "ok",
  "data": null,
  "data_error": null,
  "provider": "anthropic",
  "requested_model": "claude-sonnet-5-5",
  "model": "claude-sonnet-5-5",
  "finish_reason": "complete",
  "raw_finish_reason": "end_turn",
  "refusal": null,
  "usage": {
    "input_tokens": 23,
    "output_tokens": 4,
    "cache_creation_tokens": 0,
    "cache_read_tokens": 0,
    "reasoning_tokens": null,
    "stop_reason": "end_turn",
    "provider_request_id": "msg_01XXXXXXXXXXXXXXXXXXXXXXXX"
  },
  "turns": 1,
  "request_id": "msg_01XXXXXXXXXXXXXXXXXXXXXXXX",
  "tool_calls": [],
  "latency": 1.179,
  "start_time": "2026-10-22T19:41:00.988Z",
  "end_time": "2026-10-22T19:41:02.167Z"
}
```

</details>

**A structured answer** (the agent declares a `response_schema`; `text` is the JSON, `data` is it parsed)

<details>
<summary>OpenAI</summary>

```json
{
  "text": "{\"answer\":\"ok\"}",
  "data": {
    "answer": "ok"
  },
  "data_error": null,
  "provider": "openai",
  "requested_model": "gpt-5.6-terra",
  "model": "gpt-5.6-terra",
  "finish_reason": "complete",
  "raw_finish_reason": "stop",
  "refusal": null,
  "usage": {
    "input_tokens": 46,
    "output_tokens": 12,
    "cache_creation_tokens": 0,
    "cache_read_tokens": 0,
    "reasoning_tokens": 0,
    "stop_reason": "stop",
    "provider_request_id": "chatcmpl-XXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
  },
  "turns": 1,
  "request_id": "chatcmpl-XXXXXXXXXXXXXXXXXXXXXXXXXXXXX",
  "tool_calls": [],
  "latency": 0.786,
  "start_time": "2026-10-22T19:40:58.880Z",
  "end_time": "2026-10-22T19:40:59.665Z"
}
```

</details>

<details>
<summary>Anthropic</summary>

```json
{
  "text": "{\"answer\":\"ok\"}",
  "data": {
    "answer": "ok"
  },
  "data_error": null,
  "provider": "anthropic",
  "requested_model": "claude-sonnet-5-5",
  "model": "claude-sonnet-5-5",
  "finish_reason": "complete",
  "raw_finish_reason": "end_turn",
  "refusal": null,
  "usage": {
    "input_tokens": 209,
    "output_tokens": 12,
    "cache_creation_tokens": 0,
    "cache_read_tokens": 0,
    "reasoning_tokens": null,
    "stop_reason": "end_turn",
    "provider_request_id": "msg_01XXXXXXXXXXXXXXXXXXXXXXXX"
  },
  "turns": 1,
  "request_id": "msg_01XXXXXXXXXXXXXXXXXXXXXXXX",
  "tool_calls": [],
  "latency": 1.814,
  "start_time": "2026-10-22T19:41:02.167Z",
  "end_time": "2026-10-22T19:41:03.981Z"
}
```

</details>

**A truncated answer** (a 20-token limit). Both providers return `finish_reason: "truncated"` and an *empty* `text`,
because the limit was spent on hidden thinking. On OpenAI that is visible in `usage.reasoning_tokens`.

<details>
<summary>OpenAI</summary>

```json
{
  "text": "",
  "data": null,
  "data_error": null,
  "provider": "openai",
  "requested_model": "gpt-5.6-terra",
  "model": "gpt-5.6-terra",
  "finish_reason": "truncated",
  "raw_finish_reason": "length",
  "refusal": null,
  "usage": {
    "input_tokens": 30,
    "output_tokens": 20,
    "cache_creation_tokens": 0,
    "cache_read_tokens": 0,
    "reasoning_tokens": 20,
    "stop_reason": "length",
    "provider_request_id": "chatcmpl-XXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
  },
  "turns": 1,
  "request_id": "chatcmpl-XXXXXXXXXXXXXXXXXXXXXXXXXXXXX",
  "tool_calls": [],
  "latency": 1.322,
  "start_time": "2026-10-22T19:40:59.665Z",
  "end_time": "2026-10-22T19:41:00.988Z"
}
```

</details>

<details>
<summary>Anthropic</summary>

```json
{
  "text": "",
  "data": null,
  "data_error": null,
  "provider": "anthropic",
  "requested_model": "claude-sonnet-5-5",
  "model": "claude-sonnet-5-5",
  "finish_reason": "truncated",
  "raw_finish_reason": "max_tokens",
  "refusal": null,
  "usage": {
    "input_tokens": 39,
    "output_tokens": 20,
    "cache_creation_tokens": 0,
    "cache_read_tokens": 0,
    "reasoning_tokens": null,
    "stop_reason": "max_tokens",
    "provider_request_id": "msg_01XXXXXXXXXXXXXXXXXXXXXXXX"
  },
  "turns": 1,
  "request_id": "msg_01XXXXXXXXXXXXXXXXXXXXXXXX",
  "tool_calls": [],
  "latency": 0.872,
  "start_time": "2026-10-22T19:41:03.982Z",
  "end_time": "2026-10-22T19:41:04.854Z"
}
```

</details>

**Illustrative only** (not captured from a live call): a refusal, and a run where a tool was used.

<details>
<summary>A refusal</summary>

```json
{
  "text": "",
  "data": null,
  "data_error": null,
  "provider": "openai",
  "requested_model": "gpt-5.6-terra",
  "model": "gpt-5.6-terra",
  "finish_reason": "refused",
  "raw_finish_reason": "stop",
  "refusal": "I can't help with that.",
  "usage": {
    "input_tokens": 18,
    "output_tokens": 0,
    "cache_creation_tokens": 0,
    "cache_read_tokens": 0,
    "reasoning_tokens": 0,
    "stop_reason": "stop",
    "provider_request_id": "chatcmpl-XXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
  },
  "turns": 1,
  "request_id": "chatcmpl-XXXXXXXXXXXXXXXXXXXXXXXXXXXXX",
  "tool_calls": [],
  "latency": 1.045,
  "start_time": "2026-10-22T19:41:10.100Z",
  "end_time": "2026-10-22T19:41:10.245Z"
}
```

</details>

<details>
<summary>A tool loop (two turns, usage summed)</summary>

```json
{
  "text": "It costs $19.",
  "data": null,
  "data_error": null,
  "provider": "anthropic",
  "requested_model": "claude-sonnet-5-5",
  "model": "claude-sonnet-5-5",
  "finish_reason": "complete",
  "raw_finish_reason": "end_turn",
  "refusal": null,
  "usage": {
    "input_tokens": 260,
    "output_tokens": 31,
    "cache_creation_tokens": 0,
    "cache_read_tokens": 0,
    "reasoning_tokens": null,
    "stop_reason": "end_turn",
    "provider_request_id": "msg_01XXXXXXXXXXXXXXXXXXXXXXXX"
  },
  "turns": 2,
  "request_id": "msg_01XXXXXXXXXXXXXXXXXXXXXXXX",
  "tool_calls": [
    {
      "id": "toolu_01XXXXXXXXXXXXXXXXXXXXXXXX",
      "name": "price_check",
      "result": "{\"price\":\"$19\"}"
    }
  ],
  "latency": 1.179,
  "start_time": "2026-10-22T19:41:10.100Z",
  "end_time": "2026-10-22T19:41:10.379Z"
}
```

</details>

### What to rely on

- **A cut-off answer means the output limit was too low.** Raise it with the agent's [`max_tokens`](agents.md#max_tokens)
  (or `max_tokens :unlimited`). On a reasoning model the limit also pays for hidden thinking, so a cap that fits a plain
  model can truncate a reasoning one: size it with `finish_reason` in front of you, not by guessing.
- **Always check `finish_reason` before using `text` or `data`.** An empty `text` with `"truncated"` is the model telling
  you the limit was too low, not a bug.
- **`data` is only there for a finished answer.** For `"truncated"` or `"refused"` it is `null` and `data_error` is `null`
  too: the finish reason is the explanation.
- **The shape never changes between providers; the values can.** Code against the fields above, not against a provider's
  own words. When you do need the provider's word, it is in `raw_finish_reason`.
- **Treat `usage`, `model`, and `request_id` as possibly null** if you support custom providers.

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
