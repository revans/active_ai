require "test_helper"

# Adversarial XAI provider tests.
# Covers: error chunk handling, model resolution, stream_options omission,
# and the last_tool_calls / last_assistant_content compatibility gap.
#
# Strategy: stub client.chat by injecting a fake client via @client (the memoised
# ivar), or stub provider_instance at the agent level for Base#stream path tests.
#
# VERDICT legend:
#   PASS  — existing code handles it correctly
#   FIX   — a code change was required; the test describes the expected (fixed) behavior
#   DOC   — silent failure / intentional behaviour, documented here
class XAIAdversarialTest < ActiveSupport::TestCase
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

  def stub_xai_text_chunks(provider, chunks)
    stub_xai_chat(provider) do |parameters:|
      chunks.each { |c| parameters[:stream].call(c, nil) }
    end
  end

  # ── (7) XAI error chunk fires ProviderError ───────────────────────────────────
  # VERDICT: PASS — XAI#stream uses handle_chunk (inherited from OpenAI) via the
  # stream proc. The error chunk guard fires for XAI exactly as for OpenAI.

  test "xai 401 error chunk during streaming raises ProviderError" do
    provider = ActiveAI::Provider::XAI.new
    stub_xai_chat(provider) do |parameters:|
      parameters[:stream].call({
        "error" => {
          "message" => "Incorrect API key provided.",
          "type"    => "invalid_request_error",
          "code"    => "invalid_api_key"
        }
      }, nil)
    end

    raised = assert_raises(ActiveAI::ProviderError,
      "XAI 401 error chunk must raise ProviderError — handle_chunk guard must fire for XAI") do
      provider.stream(canonical) { }
    end
    assert_includes raised.message, "invalid_api_key",
      "ProviderError message must include the error code from the chunk"
  end

  test "xai 429 rate limit error chunk raises ProviderError" do
    provider = ActiveAI::Provider::XAI.new
    stub_xai_chat(provider) do |parameters:|
      parameters[:stream].call({
        "error" => {
          "message" => "Rate limit reached for requests.",
          "type"    => "requests",
          "code"    => "rate_limit_exceeded"
        }
      }, nil)
    end

    raised = assert_raises(ActiveAI::ProviderError) { provider.stream(canonical) { } }
    assert_includes raised.message, "rate_limit_exceeded"
  end

  test "xai 500 server error chunk raises ProviderError" do
    provider = ActiveAI::Provider::XAI.new
    stub_xai_chat(provider) do |parameters:|
      parameters[:stream].call({
        "error" => {
          "message" => "The server had an error.",
          "type"    => "server_error",
          "code"    => nil
        }
      }, nil)
    end

    assert_raises(ActiveAI::ProviderError) { provider.stream(canonical) { } }
  end

  test "xai error chunk with nil code falls back to type in ProviderError message" do
    provider = ActiveAI::Provider::XAI.new
    stub_xai_chat(provider) do |parameters:|
      parameters[:stream].call({
        "error" => { "message" => "Server error", "type" => "server_error", "code" => nil }
      }, nil)
    end

    raised = assert_raises(ActiveAI::ProviderError) { provider.stream(canonical) { } }
    assert_includes raised.message, "server_error",
      "when code is nil, the error type must appear in the ProviderError message"
  end

  test "xai normal streaming yields text chunks and does not raise" do
    provider = ActiveAI::Provider::XAI.new
    stub_xai_text_chunks(provider, [
      { "choices" => [{ "delta" => { "content" => "Hello" }, "finish_reason" => nil }], "usage" => nil },
      { "choices" => [{ "delta" => { "content" => " world" }, "finish_reason" => "stop" }], "usage" => nil },
      { "choices" => [], "usage" => { "prompt_tokens" => 8, "completion_tokens" => 2 }, "id" => "xai-xyz" }
    ])

    chunks = []
    assert_nothing_raised { provider.stream(canonical) { |c| chunks << c } }
    assert_equal ["Hello", " world"], chunks,
      "normal XAI streaming must still yield text chunks after error-detection is in place"
  end

  # ── (8) XAI model resolution ──────────────────────────────────────────────────
  # VERDICT: PASS — ApplicationAgent.PROVIDER_MODEL_DEFAULTS maps :xai → "grok-3".
  # resolved_model returns "grok-3" when no model DSL is declared on the subclass.

  test "xai agent with no model declared resolves to grok-3" do
    klass = Class.new(WritingAgent) { provider :xai }
    agent = klass.new(system: "test", message: "hi")
    assert_equal "grok-3", agent.resolved_model,
      "XAI agent with no model declaration must resolve to 'grok-3' from PROVIDER_MODEL_DEFAULTS"
  end

  test "xai agent with explicit model overrides PROVIDER_MODEL_DEFAULTS" do
    klass = Class.new(WritingAgent) do
      provider :xai
      model "grok-3-mini", max_tokens: 512
    end
    agent = klass.new(system: "test", message: "hi")
    assert_equal "grok-3-mini", agent.resolved_model,
      "explicit model declaration must take priority over PROVIDER_MODEL_DEFAULTS"
  end

  test "xai agent runtime model override takes highest priority" do
    klass = Class.new(WritingAgent) { provider :xai }
    agent = klass.new(system: "test", message: "hi", model: "grok-2-1212")
    assert_equal "grok-2-1212", agent.resolved_model,
      "runtime model kwarg must win over both class-level and PROVIDER_MODEL_DEFAULTS"
  end

  # ── (9) XAI stream_options omission ──────────────────────────────────────────
  # VERDICT: PASS — XAI#stream intentionally omits stream_options: { include_usage: true }.
  # xAI includes usage per-chunk natively; the flag is an OpenAI extension not
  # supported by all compatible providers.

  test "xai stream params do NOT include stream_options" do
    provider = ActiveAI::Provider::XAI.new
    captured = nil

    # Capture parameters without calling the stream proc — just inspect the payload shape.
    stub_xai_chat(provider) { |parameters:| captured = parameters }
    provider.stream(canonical) { }

    refute_nil captured, "client.chat must be called with parameters"
    refute captured.key?(:stream_options),
      "XAI stream must NOT include stream_options — xAI reports usage per-chunk natively"
  end

  test "xai stream params DO include a stream proc" do
    provider = ActiveAI::Provider::XAI.new
    captured = nil
    stub_xai_chat(provider) { |parameters:| captured = parameters }
    provider.stream(canonical) { }
    assert captured.key?(:stream),
      "XAI stream must include a :stream proc for chunk-by-chunk delivery"
    assert_respond_to captured[:stream], :call
  end

  test "openai stream params include stream_options (contrast with xai)" do
    provider = ActiveAI::Provider::OpenAI.new
    captured = nil
    fake_client = Object.new
    fake_client.define_singleton_method(:chat) { |parameters:| captured = parameters }
    provider.instance_variable_set(:@client, fake_client)
    provider.stream(canonical.merge(model: "gpt-4.1")) { }
    assert captured.key?(:stream_options),
      "OpenAI stream must include stream_options (contrast: XAI must not)"
  end

  # ── (10) XAI last_tool_calls / last_assistant_content ────────────────────────
  # VERDICT: FIX — OpenAI (and XAI which inherits it) only defines attr_reader :last_usage.
  # Base#stream calls @last_provider_instance.last_tool_calls after every stream turn.
  # Without last_tool_calls defined, any successful XAI streaming call through Base#stream
  # raises NoMethodError: undefined method 'last_tool_calls' for ActiveAI::Provider::XAI.
  #
  # Fix: add attr_reader :last_tool_calls, :last_assistant_content to OpenAI provider
  # and initialize them to [] in stream() and call(). XAI inherits the fix.

  test "xai provider responds to last_tool_calls after a successful stream" do
    provider = ActiveAI::Provider::XAI.new
    stub_xai_text_chunks(provider, [
      { "choices" => [{ "delta" => { "content" => "hi" }, "finish_reason" => nil }], "usage" => nil },
      { "choices" => [], "usage" => { "prompt_tokens" => 3, "completion_tokens" => 1 }, "id" => "x1" }
    ])

    provider.stream(canonical) { }

    assert_respond_to provider, :last_tool_calls,
      "XAI provider must respond to last_tool_calls — Base#stream calls it after every turn"
    assert_equal [], provider.last_tool_calls,
      "last_tool_calls must be [] after a text-only XAI stream (XAI does not use tools)"
  end

  test "xai provider responds to last_assistant_content after a successful stream" do
    provider = ActiveAI::Provider::XAI.new
    stub_xai_text_chunks(provider, [
      { "choices" => [{ "delta" => { "content" => "hi" }, "finish_reason" => nil }], "usage" => nil }
    ])

    provider.stream(canonical) { }

    assert_respond_to provider, :last_assistant_content,
      "XAI provider must respond to last_assistant_content — Base#stream reads it for tool turns"
    assert_equal [], provider.last_assistant_content,
      "last_assistant_content must be [] after a text-only XAI stream"
  end

  test "Base#stream via agent.complete does not raise NoMethodError for last_tool_calls on XAI" do
    # This is the full-stack crash test. Without the fix, Base#stream calls
    # @last_provider_instance.last_tool_calls immediately after the XAI stream returns,
    # producing NoMethodError. With the fix, last_tool_calls returns [] and the loop breaks.
    agent = WritingAgent.new(system: "test", message: "hi", provider: :xai)

    agent.define_singleton_method(:provider_instance) do
      prov = ActiveAI::Provider::XAI.new
      fake_client = Object.new
      fake_client.define_singleton_method(:chat) do |parameters:|
        parameters[:stream].call({
          "choices" => [{ "delta" => { "content" => "xAI says hello" }, "finish_reason" => nil }],
          "usage"   => nil
        }, nil)
        parameters[:stream].call({
          "choices" => [],
          "usage"   => { "prompt_tokens" => 5, "completion_tokens" => 3 },
          "id"      => "xai-req-1"
        }, nil)
      end
      prov.instance_variable_set(:@client, fake_client)
      prov
    end

    result = nil
    # Without fix: NoMethodError — last_tool_calls undefined on XAI provider
    # With fix: returns "xAI says hello"
    assert_nothing_raised { result = agent.complete }
    assert_equal "xAI says hello", result,
      "agent.complete must return the accumulated text from the XAI stream"
  end

  test "openai provider also responds to last_tool_calls (same fix)" do
    # OpenAI has the same gap — test that the fix covers both.
    provider = ActiveAI::Provider::OpenAI.new
    fake_client = Object.new
    fake_client.define_singleton_method(:chat) do |parameters:|
      parameters[:stream].call({
        "choices" => [{ "delta" => { "content" => "hi" }, "finish_reason" => nil }],
        "usage"   => nil
      }, nil)
    end
    provider.instance_variable_set(:@client, fake_client)

    provider.stream({ model: "gpt-4.1", max_tokens: 512, system: "test",
                      skills: [], source_files: [], messages: [{ role: "user", content: "hi" }],
                      cacheable: {} }) { }

    assert_respond_to provider, :last_tool_calls,
      "OpenAI provider must respond to last_tool_calls after the fix"
    assert_equal [], provider.last_tool_calls
  end

  # XAI call() path also needs last_tool_calls / last_assistant_content
  test "openai provider responds to last_tool_calls after call()" do
    provider    = ActiveAI::Provider::OpenAI.new
    fake_client = Object.new
    fake_client.define_singleton_method(:chat) do |parameters:|
      { "choices" => [{ "message" => { "content" => "reply" }, "finish_reason" => "stop" }],
        "usage" => { "prompt_tokens" => 5, "completion_tokens" => 1 }, "id" => "oai-1" }
    end
    provider.instance_variable_set(:@client, fake_client)

    provider.call({ model: "gpt-4.1", max_tokens: 512, system: "test",
                    skills: [], source_files: [], messages: [{ role: "user", content: "hi" }],
                    cacheable: {} })

    assert_respond_to provider, :last_tool_calls,
      "last_tool_calls must be accessible after a blocking call() invocation"
    assert_equal [], provider.last_tool_calls
  end
end
