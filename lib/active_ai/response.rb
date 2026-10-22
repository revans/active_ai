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
  #
  # A truncated or refused answer is a Response, not an exception: the model did answer, and the caller
  # decides what to do. Exceptions (ProviderError) are for the failure to get an answer at all.
  Response = Data.define(
    :text, :data, :data_error, :provider, :requested_model, :model,
    :finish_reason, :raw_finish_reason, :refusal, :usage, :turns,
    :request_id, :tool_calls, :latency
  ) do
    def complete? = finish_reason == :complete
    def truncated? = finish_reason == :truncated
    def refused? = finish_reason == :refused
    def tool_use? = finish_reason == :tool_use

    # Plain JSON-friendly Hash (symbols become strings), for storing or logging.
    def as_json(*) = to_h.as_json
  end

  # The unified vocabulary for why a model stopped. Each provider maps its own words onto these.
  Response::FINISH_REASONS = %i[complete truncated tool_use refused other].freeze
end
