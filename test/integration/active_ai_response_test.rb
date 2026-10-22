require "test_helper"

# The unified Response envelope: the same fields, in the same vocabulary, whichever provider answered.
# Providers are the real classes with fake SDK clients, so the finish-reason mapping and the
# served-model capture exercised here are the production code.
class ResponseEnvelopeTest < ActiveSupport::TestCase
  include ActiveAI::TestHelper

  SCHEMA = { type: "object", properties: { answer: { type: "string" } }, required: [ "answer" ], additionalProperties: false }.freeze

  # ── fakes ────────────────────────────────────────────────────────────────────

  def openai_provider(text: '{"answer":"ok"}', finish: "stop", model: "gpt-x-2026-01-01", reasoning: 7, refusal: nil, request_id: "chatcmpl-1")
    chunks = []
    chunks << { "model" => model, "choices" => [ { "delta" => { "content" => text } } ] } if text
    chunks << { "model" => model, "choices" => [ { "delta" => { "refusal" => refusal } } ] } if refusal
    chunks << { "model" => model, "choices" => [ { "delta" => {}, "finish_reason" => finish } ] }
    chunks << { "model" => model, "id" => request_id, "choices" => [], "usage" => { "prompt_tokens" => 11, "completion_tokens" => 9, "completion_tokens_details" => { "reasoning_tokens" => reasoning } } }
    client = Object.new
    client.define_singleton_method(:chat) { |parameters:| chunks.each { |chunk| parameters[:stream].call(chunk, nil) } }
    ActiveAI::Provider::OpenAI.new.tap { |provider| provider.instance_variable_set(:@client, client) }
  end

  Block = Struct.new(:type, :text)
  Usage = Struct.new(:input_tokens, :output_tokens)
  AMessage = Struct.new(:content, :stop_reason, :usage, :id, :model)

  def anthropic_provider(text: '{"answer":"ok"}', stop_reason: :end_turn, model: "claude-x-20260101", request_id: "msg_1")
    message = AMessage.new([ Block.new(:text, text) ], stop_reason, Usage.new(12, 8), request_id, model)
    stream = Object.new
    stream.define_singleton_method(:text) { [ text ].each }
    stream.define_singleton_method(:accumulated_message) { message }
    messages = Object.new
    messages.define_singleton_method(:stream) { |**| stream }
    client = Object.new
    client.define_singleton_method(:messages) { messages }
    ActiveAI::Provider::Anthropic.new.tap { |provider| provider.instance_variable_set(:@client, client) }
  end

  def agent_for(provider, provider_name, schema: nil)
    klass = Class.new(WritingAgent) do
      provider provider_name
      response_schema(schema) if schema
    end
    klass.new(system: "s", message: "hi", model: "requested-model").tap { |agent| agent.define_singleton_method(:provider_instance) { provider } }
  end

  # ── finish reasons: every word each provider uses, in one vocabulary ─────────

  test "OpenAI's finish reasons map onto the unified vocabulary" do
    { "stop" => :complete, "length" => :truncated, "tool_calls" => :tool_use, "function_call" => :tool_use,
      "content_filter" => :refused, "something_new" => :other }.each do |raw, expected|
      provider = openai_provider(finish: raw)
      provider.stream(model: "m", max_tokens: 1, system: "s", skills: [], source_files: [], messages: [ { role: "user", content: "x" } ], cacheable: {}) { }
      assert_equal expected, provider.last_finish_reason, "OpenAI #{raw.inspect}"
      assert_equal raw, provider.last_raw_finish_reason
    end
  end

  test "Anthropic's stop reasons map onto the same vocabulary" do
    { end_turn: :complete, stop_sequence: :complete, max_tokens: :truncated, model_context_window_exceeded: :truncated,
      tool_use: :tool_use, refusal: :refused, pause_turn: :other, something_new: :other }.each do |raw, expected|
      provider = anthropic_provider(stop_reason: raw)
      provider.stream(model: "m", max_tokens: 1, system: "s", skills: [], source_files: [], messages: [ { role: "user", content: "x" } ], cacheable: {}) { }
      assert_equal expected, provider.last_finish_reason, "Anthropic #{raw.inspect}"
      assert_equal raw.to_s, provider.last_raw_finish_reason, "the raw word is a String on both providers"
    end
  end

  test "every mapped value is in the published vocabulary" do
    mapped = ActiveAI::Provider::OpenAI::FINISH_REASONS.values + ActiveAI::Provider::Anthropic::FINISH_REASONS.values
    assert_empty mapped.uniq - ActiveAI::Response::FINISH_REASONS
  end

  # ── served model ─────────────────────────────────────────────────────────────

  test "the model that served the request is captured, separate from the one asked for" do
    openai = agent_for(openai_provider(model: "gpt-x-2026-01-01"), :openai).generate
    assert_equal "gpt-x-2026-01-01", openai.model
    assert_equal "requested-model", openai.requested_model
    assert_equal :openai, openai.provider

    anthropic = agent_for(anthropic_provider(model: "claude-x-20260101"), :anthropic).generate
    assert_equal "claude-x-20260101", anthropic.model
    assert_equal :anthropic, anthropic.provider
  end

  test "blocking calls capture the served model and finish reason too" do
    provider = ActiveAI::Provider::OpenAI.new
    client = Object.new
    client.define_singleton_method(:chat) { |parameters:| { "model" => "gpt-served", "id" => "c1", "choices" => [ { "finish_reason" => "length", "message" => { "content" => "partial" } } ], "usage" => { "prompt_tokens" => 1, "completion_tokens" => 2 } } }
    provider.instance_variable_set(:@client, client)
    provider.call(model: "m", max_tokens: 1, system: "s", skills: [], source_files: [], messages: [ { role: "user", content: "x" } ], cacheable: {})
    assert_equal "gpt-served", provider.last_model
    assert_equal :truncated, provider.last_finish_reason
  end

  # ── the envelope ─────────────────────────────────────────────────────────────

  test "generate returns the same fields for both providers" do
    [ [ openai_provider, :openai, 7 ], [ anthropic_provider, :anthropic, nil ] ].each do |provider, name, reasoning|
      response = agent_for(provider, name, schema: SCHEMA).generate

      assert_kind_of ActiveAI::Response, response
      assert_equal '{"answer":"ok"}', response.text
      assert_equal({ "answer" => "ok" }, response.data)
      assert_nil response.data_error
      assert response.complete?
      assert_equal :complete, response.finish_reason
      assert_equal 1, response.turns
      assert_operator response.latency, :>=, 0
      assert_predicate response.request_id, :present?
      assert_operator response.usage[:input_tokens], :>, 0
      assert_operator response.usage[:output_tokens], :>, 0
      if reasoning
        assert_equal reasoning, response.usage[:reasoning_tokens], "reasoning tokens are reported where the provider reports them"
      else
        assert_nil response.usage[:reasoning_tokens], "and nil where it does not (Anthropic folds thinking into output tokens)"
      end
      assert_equal response.usage[:provider_request_id], response.request_id
    end
  end

  test "a truncated answer is a response, not an error, and says so on both providers" do
    { openai: openai_provider(text: "1, 2, 3, 4", finish: "length"), anthropic: anthropic_provider(text: "1, 2, 3, 4", stop_reason: :max_tokens) }.each do |name, provider|
      response = nil
      assert_nothing_raised { response = agent_for(provider, name).generate }
      assert response.truncated?
      assert_equal :truncated, response.finish_reason
      assert_equal "1, 2, 3, 4", response.text, "the partial text is still there for the app to use"
      assert_includes %w[length max_tokens], response.raw_finish_reason
    end
  end

  test "an empty truncated answer (the limit spent on hidden thinking) is still a clear response" do
    response = agent_for(openai_provider(text: nil, finish: "length", reasoning: 20), :openai).generate
    assert response.truncated?
    assert_equal "", response.text
    assert_equal 20, response.usage[:reasoning_tokens]
  end

  test "a refusal is a response with the reason" do
    response = agent_for(openai_provider(text: nil, refusal: "I can't help with that."), :openai, schema: SCHEMA).generate
    assert response.refused?
    assert_equal "I can't help with that.", response.refusal
    assert_nil response.data

    assert agent_for(anthropic_provider(text: "", stop_reason: :refusal), :anthropic).generate.refused?
  end

  test "structured data is parsed only for a finished answer" do
    truncated = agent_for(openai_provider(text: '{"answer": "ok and then', finish: "length"), :openai, schema: SCHEMA).generate
    assert_nil truncated.data
    assert_nil truncated.data_error, "the finish reason is the explanation, not a JSON error"

    broken = agent_for(openai_provider(text: "Sure, here you go!"), :openai, schema: SCHEMA).generate
    assert_nil broken.data
    assert_match "not valid JSON", broken.data_error

    array = agent_for(openai_provider(text: "[1,2]"), :openai, schema: SCHEMA).generate
    assert_match "expected a JSON object", array.data_error
  end

  test "without a schema there is no data and no data_error" do
    response = agent_for(openai_provider(text: "hello"), :openai).generate
    assert_nil response.data
    assert_nil response.data_error
  end

  test "usage is summed across a tool loop, while last_usage stays the final call" do
    calls = [
      { usage: { input_tokens: 100, output_tokens: 10, cache_creation_tokens: 0, cache_read_tokens: 5, reasoning_tokens: nil, provider_request_id: "r1", stop_reason: "tool_use" }, tools: [ { id: "t1", name: "ping", input: {} } ], finish: "tool_use" },
      { usage: { input_tokens: 150, output_tokens: 20, cache_creation_tokens: 0, cache_read_tokens: 0, reasoning_tokens: nil, provider_request_id: "r2", stop_reason: "end_turn" }, tools: [], finish: "end_turn" }
    ]
    turn = -1
    scripted = Object.new
    scripted.define_singleton_method(:stream) { |_params, &block| turn += 1; block.call("done") if turn == 1 }
    scripted.define_singleton_method(:last_usage) { calls[turn][:usage] }
    scripted.define_singleton_method(:last_tool_calls) { calls[turn][:tools] }
    scripted.define_singleton_method(:last_assistant_content) { [] }
    scripted.define_singleton_method(:last_model) { "m-served" }
    scripted.define_singleton_method(:last_raw_finish_reason) { calls[turn][:finish] }
    scripted.define_singleton_method(:last_refusal) { nil }
    scripted.define_singleton_method(:last_finish_reason) { calls[turn][:finish] == "end_turn" ? :complete : :tool_use }
    scripted.define_singleton_method(:format_assistant_turn) { |content, _| { role: "assistant", content: content } }
    scripted.define_singleton_method(:format_tool_result_messages) { |results| [ { role: "user", content: results } ] }

    agent = WritingAgent.new(system: "s", message: "hi")
    agent.define_singleton_method(:provider_instance) { scripted }
    response = agent.generate

    assert_equal 2, response.turns
    assert_equal 250, response.usage[:input_tokens]
    assert_equal 30, response.usage[:output_tokens]
    assert_equal 5, response.usage[:cache_read_tokens]
    assert_nil response.usage[:reasoning_tokens], "nil stays nil when no call reported it"
    assert_equal "r2", response.request_id, "request id and stop reason come from the final call"
    assert response.complete?
    assert_equal [ "ping" ], response.tool_calls.map { |call| call[:name] }
    assert_equal 150, agent.last_usage[:input_tokens], "last_usage keeps its existing meaning"
  end

  test "a provider that reports none of this still yields a usable response" do
    agent = WritingAgent.new(system: "s", message: "hi")
    stub_ai_response(agent, response: "hello")
    response = agent.generate
    assert_equal "hello", response.text
    assert_equal :other, response.finish_reason
    assert_nil response.model
    assert_nil response.usage
    assert_equal 0, response.turns
  end

  test "complete is unchanged: it still returns the text, truncated or not, without raising" do
    assert_equal "1, 2", agent_for(openai_provider(text: "1, 2", finish: "length"), :openai).complete
  end

  test "last_response holds the most recent response" do
    agent = agent_for(openai_provider, :openai)
    assert_nil agent.last_response
    response = agent.generate
    assert_same response, agent.last_response
  end

  # ── complete_structured on top of the envelope ───────────────────────────────

  test "complete_structured returns the Hash for a finished answer" do
    assert_equal({ "answer" => "ok" }, agent_for(openai_provider, :openai, schema: SCHEMA).complete_structured)
  end

  test "complete_structured explains a refusal and a cut-off precisely" do
    refused = assert_raises(ActiveAI::StructuredOutputError) { agent_for(openai_provider(text: nil, refusal: "No."), :openai, schema: SCHEMA).complete_structured }
    assert_match "the model declined to answer: No.", refused.message

    cut = assert_raises(ActiveAI::StructuredOutputError) { agent_for(anthropic_provider(text: '{"answer":', stop_reason: :max_tokens), :anthropic, schema: SCHEMA).complete_structured }
    assert_match(/cut off at the token limit.*"max_tokens".*raise max_tokens/, cut.message)
  end

  # ── serialization ────────────────────────────────────────────────────────────

  test "as_json is plain JSON-friendly data" do
    json = agent_for(openai_provider, :openai, schema: SCHEMA).generate.as_json
    assert_equal "complete", json["finish_reason"]
    assert_equal "openai", json["provider"]
    assert_equal "gpt-x-2026-01-01", json["model"]
    assert_equal "requested-model", json["requested_model"]
    assert_equal({ "answer" => "ok" }, json["data"])
    assert_equal 11, json["usage"]["input_tokens"]
    assert_nothing_raised { JSON.generate(json) }
    assert json.keys.none? { |key| key.is_a?(Symbol) }
  end

  test "the predicates agree with finish_reason" do
    ActiveAI::Response::FINISH_REASONS.each do |reason|
      response = ActiveAI::Response.new(text: "", data: nil, data_error: nil, provider: :x, requested_model: "m", model: "m", finish_reason: reason,
                                        raw_finish_reason: nil, refusal: nil, usage: nil, turns: 1, request_id: nil, tool_calls: [], latency: 0)
      assert_equal reason == :complete, response.complete?
      assert_equal reason == :truncated, response.truncated?
      assert_equal reason == :refused, response.refused?
      assert_equal reason == :tool_use, response.tool_use?
    end
  end
end
