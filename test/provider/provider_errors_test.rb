require "test_helper"

# A provider's own explanation of a failure must reach the caller. Before this, an HTTP 400 from OpenAI
# surfaced as "the server responded with status 400", and the actual reason ("Unsupported parameter:
# 'max_tokens' ... Use 'max_completion_tokens'") was dropped on the floor.
class ProviderErrorsTest < ActiveSupport::TestCase
  OPENAI_BODY = {
    "error" => {
      "message" => "Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead.",
      "type" => "invalid_request_error", "param" => "max_tokens", "code" => "unsupported_parameter"
    }
  }.freeze

  def canonical
    { model: "m", max_tokens: 10, system: "s", skills: [], source_files: [], messages: [ { role: "user", content: "the prompt text" } ], cacheable: {} }
  end

  def faraday_error(klass, status:, body:, message: "the server responded with status #{status} for POST https://api.example.com/v1/chat/completions", headers: {})
    klass.new(message, { status: status, body: body, headers: headers })
  end

  # A provider whose client raises `error` on chat, for both blocking and streaming calls.
  def provider_failing_with(provider_class, error)
    provider = provider_class.new
    client = Object.new
    client.define_singleton_method(:chat) { |**| raise error }
    provider.instance_variable_set(:@client, client)
    provider
  end

  def raised_by(provider, method = :call)
    assert_raises(ActiveAI::ProviderError) { method == :call ? provider.call(canonical) : provider.stream(canonical) { } }
  end

  # ── OpenAI ───────────────────────────────────────────────────────────────────

  test "an OpenAI 400 carries the provider's explanation, type, code and param" do
    original = faraday_error(Faraday::BadRequestError, status: 400, body: OPENAI_BODY)
    raised = raised_by(provider_failing_with(ActiveAI::Provider::OpenAI, original))

    assert_includes raised.message, "OpenAI: HTTP 400"
    assert_includes raised.message, "(invalid_request_error/unsupported_parameter)"
    assert_includes raised.message, "[param: max_tokens]"
    assert_includes raised.message, "Use 'max_completion_tokens' instead."
    assert_equal 400, raised.status
    assert_equal "invalid_request_error", raised.type
    assert_equal "unsupported_parameter", raised.code
    assert_equal "max_tokens", raised.param
    assert_equal OPENAI_BODY["error"]["message"], raised.provider_message
    assert_same original, raised.cause
    refute raised.network?
    refute raised.retryable?
  end

  test "streaming calls report the same detail" do
    raised = raised_by(provider_failing_with(ActiveAI::Provider::OpenAI, faraday_error(Faraday::BadRequestError, status: 400, body: OPENAI_BODY)), :stream)
    assert_includes raised.message, "Use 'max_completion_tokens' instead."
    assert_equal 400, raised.status
  end

  test "a JSON body that arrives as a string is read too" do
    raised = raised_by(provider_failing_with(ActiveAI::Provider::OpenAI, faraday_error(Faraday::BadRequestError, status: 400, body: OPENAI_BODY.to_json)))
    assert_includes raised.message, "Use 'max_completion_tokens' instead."
    assert_equal "max_tokens", raised.param
  end

  # What the SDK really hands back when streaming: the first 141 bytes of the body, cut off mid-object.
  # Captured from a live OpenAI 400 for gpt-5.6-luna with max_tokens.
  CUT_OFF_BODY = "{\n  \"error\": {\n    \"message\": \"Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead.\",\n ".freeze

  test "a body cut off mid-object (as the SDK delivers it while streaming) still yields the explanation" do
    assert_raises(JSON::ParserError) { JSON.parse(CUT_OFF_BODY) }
    %i[call stream].each do |method|
      raised = raised_by(provider_failing_with(ActiveAI::Provider::OpenAI, faraday_error(Faraday::BadRequestError, status: 400, body: CUT_OFF_BODY)), method)
      assert_equal "OpenAI: HTTP 400: Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead.", raised.message
      assert_equal 400, raised.status
    end
  end

  test "a cut-off body keeps whichever fields arrived whole, and decodes escapes" do
    body = %({"error": {"message": "Model \\"x\\" is gone\\nuse y", "type": "invalid_request_error", "code": "model_not_f)
    raised = raised_by(provider_failing_with(ActiveAI::Provider::OpenAI, faraday_error(Faraday::BadRequestError, status: 400, body: body)))
    assert_includes raised.message, %(Model "x" is gone use y)
    assert_equal "invalid_request_error", raised.type
    assert_nil raised.code, "a field cut off mid-value must not be half-reported"
  end

  test "a body cut off inside the message falls back to the exception's own text" do
    raised = raised_by(provider_failing_with(ActiveAI::Provider::OpenAI, faraday_error(Faraday::BadRequestError, status: 400, body: %({"error": {"message": "Unsupported par))))
    assert_includes raised.message, "the server responded with status 400"
    refute_includes raised.message, "Unsupported par"
  end

  test "a gateway that sends a plain-string error is read" do
    raised = raised_by(provider_failing_with(ActiveAI::Provider::OpenAI, faraday_error(Faraday::ServerError, status: 503, body: { "error" => "upstream is down" })))
    assert_includes raised.message, "HTTP 503"
    assert_includes raised.message, "upstream is down"
    assert raised.retryable?
  end

  test "an HTML error page is not dumped into the message; the SDK's own text is used instead" do
    html = "<html><body><h1>502 Bad Gateway</h1><p>secret internal details</p></body></html>"
    raised = raised_by(provider_failing_with(ActiveAI::Provider::OpenAI, faraday_error(Faraday::ServerError, status: 502, body: html)))
    assert_includes raised.message, "HTTP 502"
    assert_includes raised.message, "the server responded with status 502"
    refute_includes raised.message, "<html"
    refute_includes raised.message, "secret internal details"
    assert raised.retryable?
  end

  test "an empty body falls back to the exception's own message, never to nothing" do
    raised = raised_by(provider_failing_with(ActiveAI::Provider::OpenAI, faraday_error(Faraday::BadRequestError, status: 400, body: nil)))
    assert_includes raised.message, "the server responded with status 400"
  end

  test "rate limiting and authentication failures are recognisable" do
    limited = raised_by(provider_failing_with(ActiveAI::Provider::OpenAI, faraday_error(Faraday::TooManyRequestsError, status: 429, body: { "error" => { "message" => "Rate limit reached", "type" => "requests" } })))
    assert limited.rate_limited?
    assert limited.retryable?

    unauthorized = raised_by(provider_failing_with(ActiveAI::Provider::OpenAI, faraday_error(Faraday::UnauthorizedError, status: 401, body: { "error" => { "message" => "Incorrect API key provided." } })))
    assert unauthorized.authentication_failed?
    refute unauthorized.retryable?
  end

  test "a failure with no HTTP response is a network error" do
    raised = raised_by(provider_failing_with(ActiveAI::Provider::OpenAI, Faraday::ConnectionFailed.new("Failed to open TCP connection to api.openai.com:443")))
    assert_match(/\ANetwork error: Failed to open TCP connection/, raised.message)
    assert_nil raised.status
    assert raised.network?
    assert raised.retryable?
  end

  test "an API key echoed back in an error message is redacted" do
    body = { "error" => { "message" => "Incorrect API key provided: sk-proj-abcd1234efgh5678wxyz. Find it at https://platform.openai.com/account/api-keys.", "type" => "invalid_request_error", "code" => "invalid_api_key" } }
    raised = raised_by(provider_failing_with(ActiveAI::Provider::OpenAI, faraday_error(Faraday::UnauthorizedError, status: 401, body: body)))
    refute_includes raised.message, "sk-proj"
    refute_includes raised.provider_message, "abcd1234"
    assert_includes raised.message, "[redacted]"
    assert_includes raised.message, "Incorrect API key provided"

    bearer = raised_by(provider_failing_with(ActiveAI::Provider::OpenAI, Faraday::ConnectionFailed.new("auth failed for Bearer sk-live-topsecret12345")))
    refute_includes bearer.message, "topsecret"
  end

  test "request headers and the prompt never appear in the message" do
    error = faraday_error(Faraday::BadRequestError, status: 400, body: OPENAI_BODY, headers: { "authorization" => "Bearer sk-live-topsecret12345" })
    error.response[:request] = { body: { messages: [ { content: "the prompt text" } ] }.to_json, headers: { "Authorization" => "Bearer sk-live-topsecret12345" } }
    raised = raised_by(provider_failing_with(ActiveAI::Provider::OpenAI, error))
    refute_includes raised.message, "topsecret"
    refute_includes raised.message, "the prompt text"
  end

  test "very long or control-character messages are bounded and flattened" do
    body = { "error" => { "message" => "line one\n\tline two\u0000 " + ("x" * 5000) } }
    raised = raised_by(provider_failing_with(ActiveAI::Provider::OpenAI, faraday_error(Faraday::BadRequestError, status: 400, body: body)))
    assert_operator raised.provider_message.length, :<=, ActiveAI::Provider::Base::MAX_PROVIDER_MESSAGE
    refute_match(/[[:cntrl:]]/, raised.message)
    assert_includes raised.message, "line one line two"
  end

  test "OpenAI SDK errors with no HTTP response keep their message" do
    raised = raised_by(provider_failing_with(ActiveAI::Provider::OpenAI, OpenAI::Error.new("sdk-level problem")))
    assert_equal "OpenAI: sdk-level problem", raised.message
  end

  # ── xAI ──────────────────────────────────────────────────────────────────────

  test "xAI errors say xAI, for blocking and streaming calls" do
    error = faraday_error(Faraday::BadRequestError, status: 400, body: { "error" => { "message" => "Model not found: grok-9", "code" => "model_not_found" } })
    %i[call stream].each do |method|
      raised = raised_by(provider_failing_with(ActiveAI::Provider::XAI, error), method)
      assert_match(/\AxAI: HTTP 400 \(model_not_found\): Model not found: grok-9/, raised.message)
    end
  end

  # ── Anthropic ────────────────────────────────────────────────────────────────

  def anthropic_provider_failing_with(error)
    provider = ActiveAI::Provider::Anthropic.new
    messages = Object.new
    messages.define_singleton_method(:create) { |**| raise error }
    messages.define_singleton_method(:stream) { |**| raise error }
    client = Object.new
    client.define_singleton_method(:messages) { messages }
    provider.instance_variable_set(:@client, client)
    provider
  end

  test "an Anthropic 400 carries the provider's explanation" do
    sdk_error = Anthropic::Errors::APIStatusError.for(
      url: URI("https://api.anthropic.com/v1/messages"), status: 400, headers: {}, request: nil, response: nil,
      body: { type: "error", error: { type: "invalid_request_error", message: "max_tokens: must be greater than 0" } }
    )
    %i[call stream].each do |method|
      raised = raised_by(anthropic_provider_failing_with(sdk_error), method)
      assert_includes raised.message, "Anthropic: HTTP 400 (invalid_request_error)"
      assert_includes raised.message, "max_tokens: must be greater than 0"
      assert_equal 400, raised.status
      assert_same sdk_error, raised.cause
    end
  end

  test "an Anthropic overload is retryable" do
    sdk_error = Anthropic::Errors::APIStatusError.for(
      url: URI("https://api.anthropic.com/v1/messages"), status: 529, headers: {}, request: nil, response: nil,
      body: { type: "error", error: { type: "overloaded_error", message: "Overloaded" } }
    )
    raised = raised_by(anthropic_provider_failing_with(sdk_error))
    assert raised.retryable?
    assert_equal "overloaded_error", raised.type
  end

  test "an Anthropic connection failure is a network-style error with no status" do
    sdk_error = Anthropic::Errors::APIConnectionError.new(url: URI("https://api.anthropic.com/v1/messages"), message: "Connection error.")
    raised = raised_by(anthropic_provider_failing_with(sdk_error))
    assert_nil raised.status
    assert raised.network?
    assert_includes raised.message, "Connection error."
  end

  # ── what reaches a browser over streaming ────────────────────────────────────

  test "streaming sends the cleaned provider message to the client, not a generic line" do
    host = Class.new(ActionController::Base) { include ActiveAI::Concerns::Streamable }.new
    error = ActiveAI::ProviderError.new("OpenAI: HTTP 400: ignored", provider_message: "Unsupported parameter: 'max_tokens'")
    assert_equal "Unsupported parameter: 'max_tokens'", host.send(:stream_error_message, error)
    assert_equal "Provider error. Please try again.", host.send(:stream_error_message, ActiveAI::ProviderError.new("no detail at all"))
    assert_equal "Something went wrong. Please try again.", host.send(:stream_error_message, RuntimeError.new("boom"))
  end
end
