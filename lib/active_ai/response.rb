module ActiveAI
  # What one agent call produced, in the same shape whichever provider answered.
  #
  #   response = agent.generate
  #   response.text              # the model's text (possibly partial or empty: check finish_reason)
  #   response.data              # the parsed Hash when the agent declares a response_schema
  #   response.finish_reason     # :complete, :truncated, :tool_use, :refused or :other (see providers.md)
  #   response.raw_finish_reason # what the provider actually said ("stop", "length", "end_turn", "max_tokens", ...)
  #   response.provider          # :openai, :anthropic, ...  who answered
  #   response.model             # the model that served the request, as the provider reported it
  #   response.requested_model   # the model that was asked for (often the same, sometimes an alias)
  #   response.start_time        # when the run started: a UTC Time, to the millisecond, set by ActiveAI
  #   response.end_time          # when the run ended; as_json renders both as ISO 8601 with milliseconds
  #   response.turn_log          # what the model said and asked for in each turn, in order (text is every turn's text joined)
  #
  # A truncated or refused answer is a Response, not an exception: the model did answer, and the caller
  # decides what to do. Exceptions (ProviderError) are for the failure to get an answer at all.
  Response = Data.define(
    :text, :data, :data_error, :provider, :requested_model, :model,
    :finish_reason, :raw_finish_reason, :refusal, :usage, :turns,
    :request_id, :tool_calls, :latency, :start_time, :end_time, :turn_log, :run_id
  ) do
    # turn_log is optional so a Response built before it existed (a test double, a stored one) still loads.
    def initialize(turn_log: [], run_id: nil, **fields) = super(turn_log: turn_log, run_id: run_id, **fields)

    def complete? = finish_reason == :complete
    def truncated? = finish_reason == :truncated
    def refused? = finish_reason == :refused
    def tool_use? = finish_reason == :tool_use

    # Plain JSON-friendly Hash (symbols become strings), for storing or logging. start_time and end_time are always
    # ISO 8601 UTC with exactly three fractional digits ("2026-10-22T19:47:12.345Z"), whatever precision the host
    # app has configured for JSON time encoding.
    def as_json(*) = to_h.merge(start_time: start_time&.round(3)&.iso8601(3), end_time: end_time&.round(3)&.iso8601(3)).as_json
  end

  # The unified vocabulary for why a model stopped. Each provider maps its own words onto these.
  Response::FINISH_REASONS = %i[complete truncated tool_use refused other].freeze
end
