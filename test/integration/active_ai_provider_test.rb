require "test_helper"

# Adversarial provider tests — probing what happens when credentials are nil,
# the HTTP layer returns errors, the connection times out, or the response is garbage.
#
# Stubbing strategy: inject a fake SDK client via instance_variable_set(:@client, ...)
# rather than using webmock (not installed). The provider's `client` method is memoised
# with @client ||= ..., so injecting @client before the first call intercepts everything
# without touching the network.
#
# Each test section has a one-line verdict comment:
#   PASS  — existing rescue clause handles it cleanly
#   FIX   — needed a code change to produce a typed error
#   DOC   — silent failure, documented here; no exception expected from current code

class AnthropicProviderTest < ActiveSupport::TestCase
  include ActiveAI::TestHelper

  # ── Helpers ──────────────────────────────────────────────────────────────────

  def canonical
    {
      model:        "claude-sonnet-4-6",
      max_tokens:   1024,
      system:       "test system",
      skills:       [],
      source_files: [],
      messages:     [{ role: "user", content: "test" }],
      cacheable:    {}
    }
  end

  # Fake Anthropic SDK client whose messages.stream raises on call.
  def anthropic_client_raising(error)
    fake_msgs = Object.new
    fake_msgs.define_singleton_method(:stream) { |**_| raise error }
    client    = Object.new
    client.define_singleton_method(:messages) { fake_msgs }
    client
  end

  # Fake Anthropic SDK client whose messages.stream calls the given block.
  def anthropic_client_with_stream(&impl)
    fake_msgs = Object.new
    fake_msgs.define_singleton_method(:stream, &impl)
    client    = Object.new
    client.define_singleton_method(:messages) { fake_msgs }
    client
  end

  # Minimal fake message_stream object — text yields chunks, accumulated_message returns msg.
  def fake_message_stream(chunks:, accumulated_message:)
    text_enum = Enumerator.new { |y| chunks.each { |c| y << c } }
    ms = Object.new
    ms.define_singleton_method(:text) { text_enum }
    ms.define_singleton_method(:accumulated_message) { accumulated_message }
    ms
  end

  # ── Area 1: nil API key reaches provider ─────────────────────────────────────
  # VERDICT: PASS — Anthropic SDK raises AuthenticationError on request; the provider
  # rescue ::Anthropic::Errors::Error wraps it cleanly as ProviderError.
  # We stub the SDK client so no actual HTTP call is needed.

  test "nil api_key — ProviderError is raised, not raw Anthropic::Errors::AuthenticationError" do
    err = Anthropic::Errors::AuthenticationError.new(
      url: URI("https://api.anthropic.com/v1/messages"),
      status: 401, headers: {}, body: nil, request: nil, response: nil,
      message: "401 Authentication Error: invalid x-api-key"
    )
    provider = ActiveAI::Provider::Anthropic.new
    provider.instance_variable_set(:@client, anthropic_client_raising(err))

    raised = assert_raises(ActiveAI::ProviderError, "nil key must raise ProviderError, not raw SDK error") do
      provider.stream(canonical) { }
    end
    assert_includes raised.message, "Authentication Error",
      "ProviderError message must carry the SDK error text so callers know what happened"
  end

  test "nil api_key — ProviderError.cause is the original SDK error for inspection" do
    err = Anthropic::Errors::AuthenticationError.new(
      url: URI("https://api.anthropic.com/v1/messages"),
      status: 401, headers: {}, body: nil, request: nil, response: nil,
      message: "401 Authentication Error"
    )
    provider = ActiveAI::Provider::Anthropic.new
    provider.instance_variable_set(:@client, anthropic_client_raising(err))

    raised = assert_raises(ActiveAI::ProviderError) { provider.stream(canonical) { } }
    assert_instance_of Anthropic::Errors::AuthenticationError, raised.cause,
      "cause must be preserved so callers can inspect HTTP status, headers, body"
  end

  # ── Area 2: HTTP error codes ───────────────────────────────────────────────
  # VERDICT: PASS — all status-specific errors inherit Anthropic::Errors::Error,
  # so the existing rescue clause catches all of them.

  test "anthropic 401 unauthorised raises ProviderError" do
    err = Anthropic::Errors::AuthenticationError.new(
      url: URI("https://api.anthropic.com/v1/messages"),
      status: 401, headers: {}, body: nil, request: nil, response: nil,
      message: "401 Authentication Error"
    )
    provider = ActiveAI::Provider::Anthropic.new
    provider.instance_variable_set(:@client, anthropic_client_raising(err))
    assert_raises(ActiveAI::ProviderError) { provider.stream(canonical) { } }
  end

  test "anthropic 429 rate limit raises ProviderError" do
    err = Anthropic::Errors::RateLimitError.new(
      url: URI("https://api.anthropic.com/v1/messages"),
      status: 429, headers: {}, body: nil, request: nil, response: nil,
      message: "429 Rate Limit Exceeded"
    )
    provider = ActiveAI::Provider::Anthropic.new
    provider.instance_variable_set(:@client, anthropic_client_raising(err))
    raised = assert_raises(ActiveAI::ProviderError) { provider.stream(canonical) { } }
    assert_includes raised.message, "429"
  end

  test "anthropic 500 server error raises ProviderError" do
    err = Anthropic::Errors::InternalServerError.new(
      url: URI("https://api.anthropic.com/v1/messages"),
      status: 500, headers: {}, body: nil, request: nil, response: nil,
      message: "500 Internal Server Error"
    )
    provider = ActiveAI::Provider::Anthropic.new
    provider.instance_variable_set(:@client, anthropic_client_raising(err))
    assert_raises(ActiveAI::ProviderError) { provider.stream(canonical) { } }
  end

  test "anthropic 529 overloaded raises ProviderError" do
    # 529 (Anthropic-specific overload code) → InternalServerError in the SDK
    err = Anthropic::Errors::InternalServerError.new(
      url: URI("https://api.anthropic.com/v1/messages"),
      status: 529, headers: {}, body: nil, request: nil, response: nil,
      message: "529 Overloaded"
    )
    provider = ActiveAI::Provider::Anthropic.new
    provider.instance_variable_set(:@client, anthropic_client_raising(err))
    assert_raises(ActiveAI::ProviderError) { provider.stream(canonical) { } }
  end

  test "anthropic ProviderError message includes HTTP status for all status errors" do
    [
      [401, Anthropic::Errors::AuthenticationError, "401 Auth Error"],
      [429, Anthropic::Errors::RateLimitError,      "429 Rate Limit"],
      [500, Anthropic::Errors::InternalServerError, "500 Server Error"]
    ].each do |status, klass, msg|
      err = klass.new(
        url: URI("https://api.anthropic.com/v1/messages"),
        status: status, headers: {}, body: nil, request: nil, response: nil,
        message: msg
      )
      provider = ActiveAI::Provider::Anthropic.new
      provider.instance_variable_set(:@client, anthropic_client_raising(err))
      raised = assert_raises(ActiveAI::ProviderError, "#{status} must produce ProviderError") do
        provider.stream(canonical) { }
      end
      assert_includes raised.message, status.to_s,
        "ProviderError message must include the HTTP status code (#{status})"
    end
  end

  # ── Area 3: Timeout ────────────────────────────────────────────────────────
  # VERDICT: PASS — APITimeoutError < APIConnectionError < APIError < Error,
  # all are caught by rescue ::Anthropic::Errors::Error.

  test "anthropic APITimeoutError raises ProviderError, not raw timeout exception" do
    err = Anthropic::Errors::APITimeoutError.new(
      url: URI("https://api.anthropic.com/v1/messages")
    )
    provider = ActiveAI::Provider::Anthropic.new
    provider.instance_variable_set(:@client, anthropic_client_raising(err))
    assert_raises(ActiveAI::ProviderError) { provider.stream(canonical) { } }
  end

  test "anthropic APIConnectionError raises ProviderError" do
    err = Anthropic::Errors::APIConnectionError.new(
      url: URI("https://api.anthropic.com/v1/messages"),
      message: "Connection refused — is the host reachable?"
    )
    provider = ActiveAI::Provider::Anthropic.new
    provider.instance_variable_set(:@client, anthropic_client_raising(err))
    assert_raises(ActiveAI::ProviderError) { provider.stream(canonical) { } }
  end

  test "anthropic timeout ProviderError.cause is the original SDK error" do
    err = Anthropic::Errors::APITimeoutError.new(
      url: URI("https://api.anthropic.com/v1/messages")
    )
    provider = ActiveAI::Provider::Anthropic.new
    provider.instance_variable_set(:@client, anthropic_client_raising(err))
    raised = assert_raises(ActiveAI::ProviderError) { provider.stream(canonical) { } }
    assert_instance_of Anthropic::Errors::APITimeoutError, raised.cause
  end

  # ── Area 4: Malformed response ─────────────────────────────────────────────
  # VERDICT: PASS — extract_usage, extract_tool_calls, extract_assistant_content
  # all guard with respond_to?, so a bare Object or empty Hash as accumulated_message
  # produces nil usage and empty arrays without raising.

  test "malformed accumulated_message (bare Object, no usage) — no crash, usage is nil" do
    bare_msg  = Object.new   # has no :usage, :content, :stop_reason, :id methods
    ms        = fake_message_stream(chunks: ["some text"], accumulated_message: bare_msg)
    provider  = ActiveAI::Provider::Anthropic.new
    provider.instance_variable_set(:@client, anthropic_client_with_stream { |**_| ms })

    chunks = []
    # bare accumulated_message must not crash — all extractions guard with respond_to?
    assert_nothing_raised do
      provider.stream(canonical) { |c| chunks << c }
    end
    assert_equal ["some text"], chunks, "text chunks must still be yielded before accumulated_message is parsed"
    assert_nil provider.last_usage,          "usage is nil when accumulated_message has no .usage"
    assert_equal [], provider.last_tool_calls, "tool_calls is [] when accumulated_message has no .content"
  end

  test "accumulated_message as empty Hash — no crash, returns nil usage and empty arrays" do
    ms = fake_message_stream(chunks: [], accumulated_message: {})
    provider = ActiveAI::Provider::Anthropic.new
    provider.instance_variable_set(:@client, anthropic_client_with_stream { |**_| ms })

    assert_nothing_raised { provider.stream(canonical) { } }
    assert_nil provider.last_usage
    assert_equal [], provider.last_tool_calls
    assert_equal [], provider.last_assistant_content
  end

  test "empty text enumeration with valid accumulated_message structure — yields no chunks" do
    # Simulates a response where the API sent usage data but no text (e.g., tool-only turn)
    fake_usage    = Struct.new(:input_tokens, :output_tokens).new(10, 0)
    fake_msg      = Struct.new(:usage, :content, :stop_reason, :id).new(fake_usage, [], "tool_use", "msg_abc")
    ms            = fake_message_stream(chunks: [], accumulated_message: fake_msg)

    provider = ActiveAI::Provider::Anthropic.new
    provider.instance_variable_set(:@client, anthropic_client_with_stream { |**_| ms })

    chunks = []
    assert_nothing_raised { provider.stream(canonical) { |c| chunks << c } }
    assert_empty chunks, "no text chunks when streaming a tool-only response"
    # usage should be extracted (input_tokens: 10, output_tokens: 0)
    refute_nil provider.last_usage
    assert_equal 10, provider.last_usage[:input_tokens]
    assert_equal 0,  provider.last_usage[:output_tokens]
  end

  # ── Area 5: Empty stream ──────────────────────────────────────────────────
  # VERDICT: PASS — Base#complete accumulates into String.new(""), so empty stream
  # returns "" not nil. No downstream caller gets a nil to choke on.

  test "empty stream — complete returns empty String, not nil" do
    klass = Class.new(WritingAgent) do
      define_method(:provider_instance) do
        prov = Object.new
        prov.define_singleton_method(:stream)                 { |_params, &_blk| }
        prov.define_singleton_method(:last_usage)             { nil }
        prov.define_singleton_method(:last_tool_calls)        { [] }
        prov.define_singleton_method(:last_assistant_content) { [] }
        prov
      end
    end

    result = klass.new(system: "test", message: "hi").complete
    assert_instance_of String, result, "complete must return a String even when stream yields nothing"
    assert_equal "", result
  end

  test "empty stream — last_usage is nil, no NoMethodError accessing it after complete" do
    klass = Class.new(WritingAgent) do
      define_method(:provider_instance) do
        prov = Object.new
        prov.define_singleton_method(:stream)                 { |_params, &_blk| }
        prov.define_singleton_method(:last_usage)             { nil }
        prov.define_singleton_method(:last_tool_calls)        { [] }
        prov.define_singleton_method(:last_assistant_content) { [] }
        prov
      end
    end

    agent = klass.new(system: "test", message: "hi")
    agent.complete
    assert_nil agent.last_usage,
      "empty stream must produce nil last_usage, not raise when caller reads it"
  end

  # ── Area 6: Provider not configured ───────────────────────────────────────
  # VERDICT: PASS — resolved_provider always falls through to config default;
  # unknown provider names raise ConfigurationError before any HTTP call.

  test "agent with no provider DSL call resolves to config default (:anthropic)" do
    klass = Class.new(ApplicationAgent)
    agent = klass.new(system: "test", message: "hi")
    assert_equal :anthropic, agent.send(:resolved_provider)
  end

  test "agent with unknown provider raises ConfigurationError immediately (no HTTP attempt)" do
    klass = Class.new(ApplicationAgent) { provider :no_such_provider }
    agent = klass.new(system: "test", message: "hi")
    error = assert_raises(ActiveAI::ConfigurationError) { agent.stream { } }
    assert_match "no_such_provider", error.message
    assert_match(/Unknown/i, error.message)
  end
end

class OpenAIProviderTest < ActiveSupport::TestCase
  include ActiveAI::TestHelper

  # ── Helpers ──────────────────────────────────────────────────────────────────

  def canonical
    {
      model:        "gpt-4.1",
      max_tokens:   1024,
      system:       "test system",
      skills:       [],
      source_files: [],
      messages:     [{ role: "user", content: "test" }],
      cacheable:    {}
    }
  end

  def stub_openai_chat(provider, &impl)
    fake_client = Object.new
    fake_client.define_singleton_method(:chat, &impl)
    provider.instance_variable_set(:@client, fake_client)
  end

  # Stubs client.chat so it calls the stream proc with the given chunk.
  # This simulates the OpenAI gem's Stream class yielding an error-shaped hash
  # when the API returns a non-200 status formatted as an SSE data event.
  def stub_openai_streaming_error_chunk(provider, error_chunk)
    stub_openai_chat(provider) do |parameters:|
      parameters[:stream].call(error_chunk, nil)
    end
  end

  # Stubs client.chat so it calls the stream proc with a sequence of real chunks.
  def stub_openai_streaming_chunks(provider, chunks)
    stub_openai_chat(provider) do |parameters:|
      chunks.each { |chunk| parameters[:stream].call(chunk, nil) }
    end
  end

  # ── Area 3: Timeout (OpenAI/XAI) ──────────────────────────────────────────
  # VERDICT: FIX APPLIED — Faraday::Error is NOT a subclass of OpenAI::Error,
  # so the existing rescue clause missed it entirely. A raw Faraday::TimeoutError
  # would propagate out of stream/call without any ActiveAI wrapping.
  # Fix: added rescue Faraday::Error in OpenAI#stream, OpenAI#call, XAI#stream.

  test "openai Faraday::TimeoutError raises ProviderError, not raw Faraday error" do
    provider = ActiveAI::Provider::OpenAI.new
    stub_openai_chat(provider) { |**_| raise Faraday::TimeoutError, "execution expired" }

    raised = assert_raises(ActiveAI::ProviderError,
      "Faraday::TimeoutError must be wrapped as ProviderError — callers must not see raw Faraday errors") do
      provider.stream(canonical) { }
    end
    assert_includes raised.message, "execution expired"
  end

  test "openai Faraday::ConnectionFailed raises ProviderError" do
    provider = ActiveAI::Provider::OpenAI.new
    stub_openai_chat(provider) { |**_| raise Faraday::ConnectionFailed, "connection refused" }

    assert_raises(ActiveAI::ProviderError) { provider.stream(canonical) { } }
  end

  test "openai Faraday::TimeoutError in call raises ProviderError" do
    provider = ActiveAI::Provider::OpenAI.new
    stub_openai_chat(provider) { |**_| raise Faraday::TimeoutError, "execution expired" }

    assert_raises(ActiveAI::ProviderError) { provider.call(canonical) }
  end

  test "openai ProviderError.cause for timeout is the original Faraday error" do
    faraday_err = Faraday::TimeoutError.new("execution expired")
    provider    = ActiveAI::Provider::OpenAI.new
    stub_openai_chat(provider) { |**_| raise faraday_err }

    raised = assert_raises(ActiveAI::ProviderError) { provider.stream(canonical) { } }
    assert_instance_of Faraday::TimeoutError, raised.cause
  end

  # ── Area 2: HTTP error chunks during streaming (OpenAI) ───────────────────
  # VERDICT: FIX — When the OpenAI API returns a 401/429/500 while streaming,
  # the ruby-openai gem's Stream class may yield an error-shaped hash to the
  # user proc instead of (or before) raising a Faraday error:
  #   { "error" => { "message" => "...", "type" => "...", "code" => "..." } }
  # Previously handle_chunk only looked at chunk["choices"] and chunk["usage"],
  # so error chunks were silently ignored: accumulator stayed empty, last_usage
  # was nil, complete returned "". No exception was raised.
  # Fix: detect chunk["error"] in handle_chunk and raise ActiveAI::ProviderError.

  test "openai 401 error chunk during streaming raises ProviderError" do
    provider = ActiveAI::Provider::OpenAI.new
    stub_openai_streaming_error_chunk(provider, {
      "error" => {
        "message" => "Incorrect API key provided.",
        "type"    => "invalid_request_error",
        "param"   => nil,
        "code"    => "invalid_api_key"
      }
    })

    raised = assert_raises(ActiveAI::ProviderError,
      "401 error chunk must raise ProviderError, not silently produce empty string") do
      provider.stream(canonical) { }
    end
    assert_includes raised.message, "invalid_api_key",
      "ProviderError message must include the error code so callers know what failed"
  end

  test "openai 429 rate limit error chunk during streaming raises ProviderError" do
    provider = ActiveAI::Provider::OpenAI.new
    stub_openai_streaming_error_chunk(provider, {
      "error" => {
        "message" => "Rate limit reached for requests.",
        "type"    => "requests",
        "param"   => nil,
        "code"    => "rate_limit_exceeded"
      }
    })

    raised = assert_raises(ActiveAI::ProviderError,
      "429 rate limit chunk must raise ProviderError") do
      provider.stream(canonical) { }
    end
    assert_includes raised.message, "rate_limit_exceeded"
  end

  test "openai 500 server error chunk during streaming raises ProviderError" do
    provider = ActiveAI::Provider::OpenAI.new
    stub_openai_streaming_error_chunk(provider, {
      "error" => {
        "message" => "The server had an error processing your request.",
        "type"    => "server_error",
        "param"   => nil,
        "code"    => nil
      }
    })

    assert_raises(ActiveAI::ProviderError,
      "500 server error chunk must raise ProviderError") do
      provider.stream(canonical) { }
    end
  end

  test "openai error chunk ProviderError message includes code when present, type as fallback" do
    # code nil → falls back to type
    provider = ActiveAI::Provider::OpenAI.new
    stub_openai_streaming_error_chunk(provider, {
      "error" => { "message" => "Server error", "type" => "server_error", "code" => nil }
    })

    raised = assert_raises(ActiveAI::ProviderError) { provider.stream(canonical) { } }
    assert_includes raised.message, "server_error",
      "when code is nil the error type must appear in the ProviderError message"
  end

  test "openai normal streaming yields text chunks and does not raise" do
    provider = ActiveAI::Provider::OpenAI.new
    stub_openai_streaming_chunks(provider, [
      { "choices" => [{ "delta" => { "content" => "Hello" }, "finish_reason" => nil }], "usage" => nil },
      { "choices" => [{ "delta" => { "content" => " world" }, "finish_reason" => "stop" }], "usage" => nil },
      { "choices" => [], "usage" => { "prompt_tokens" => 10, "completion_tokens" => 2 }, "id" => "chatcmpl-xyz" }
    ])

    chunks = []
    assert_nothing_raised { provider.stream(canonical) { |c| chunks << c } }
    assert_equal ["Hello", " world"], chunks,
      "normal streaming must still yield text chunks after error-detection fix"
    refute_nil provider.last_usage, "normal streaming must still populate last_usage"
  end

  test "openai client.chat returning nil — stream completes empty with no exception" do
    # When client.chat returns nil without calling the stream proc at all,
    # there is no error info to surface — silent empty completion is acceptable.
    provider = ActiveAI::Provider::OpenAI.new
    stub_openai_chat(provider) { |**_| nil }

    chunks = []
    assert_nothing_raised { provider.stream(canonical) { |c| chunks << c } }
    assert_empty chunks
    assert_nil provider.last_usage
  end

  test "openai OpenAI::Error in stream raises ProviderError" do
    provider = ActiveAI::Provider::OpenAI.new
    stub_openai_chat(provider) { |**_| raise OpenAI::Error, "explicit SDK error" }

    assert_raises(ActiveAI::ProviderError) { provider.stream(canonical) { } }
  end

  test "openai OpenAI::Error in call raises ProviderError" do
    provider = ActiveAI::Provider::OpenAI.new
    stub_openai_chat(provider) { |**_| raise OpenAI::Error, "explicit SDK error" }

    assert_raises(ActiveAI::ProviderError) { provider.call(canonical) }
  end
end

class XAIProviderTest < ActiveSupport::TestCase
  # XAI extends OpenAI — test that its overridden stream method has the same Faraday fix.

  def canonical
    {
      model:        "grok-3",
      max_tokens:   1024,
      system:       "test system",
      skills:       [],
      source_files: [],
      messages:     [{ role: "user", content: "test" }],
      cacheable:    {}
    }
  end

  def stub_xai_chat(provider, &impl)
    fake_client = Object.new
    fake_client.define_singleton_method(:chat, &impl)
    provider.instance_variable_set(:@client, fake_client)
  end

  test "xai Faraday::TimeoutError raises ProviderError (overridden stream method)" do
    provider = ActiveAI::Provider::XAI.new
    stub_xai_chat(provider) { |**_| raise Faraday::TimeoutError, "execution expired" }

    assert_raises(ActiveAI::ProviderError,
      "XAI#stream overrides OpenAI#stream and must also rescue Faraday::Error") do
      provider.stream(canonical) { }
    end
  end
end
