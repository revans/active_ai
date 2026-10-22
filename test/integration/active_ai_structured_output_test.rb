require "test_helper"

# Structured output (response_schema / complete_structured), the provider_options escape hatch,
# and per-call skills in every shape. Providers are faked at the SDK client; nothing touches the network.
class StructuredOutputTest < ActiveSupport::TestCase
  include ActiveAI::TestHelper

  SCHEMA = {
    type: "object",
    properties: { answer: { type: "string" } },
    required: [ "answer" ],
    additionalProperties: false
  }.freeze

  def agent_class(provider: :openai, &block)
    Class.new(WritingAgent) do
      provider provider
      class_eval(&block) if block
    end
  end

  def canonical(extra = {})
    { model: "m", max_tokens: 50, system: "s", skills: [], source_files: [], messages: [ { role: "user", content: "hi" } ], cacheable: {} }.merge(extra)
  end

  # ── response_schema on the agent ─────────────────────────────────────────────

  test "response_schema is stored with string keys and a default name" do
    klass = agent_class { response_schema SCHEMA }
    stored = klass._response_schema
    assert_equal "response", stored[:name]
    assert_equal true, stored[:strict]
    assert_equal "object", stored[:schema]["type"]
    assert_equal [ "answer" ], stored[:schema]["required"]
  end

  test "response_schema takes a name, description and strict flag" do
    klass = agent_class { response_schema SCHEMA, name: "reply_v1", description: "A reply.", strict: false }
    assert_equal({ name: "reply_v1", description: "A reply.", strict: false }, klass._response_schema.slice(:name, :description, :strict))
  end

  test "response_schema refuses a bad name or a non-hash" do
    assert_raises(ArgumentError) { agent_class { response_schema SCHEMA, name: "has spaces" } }
    assert_raises(ArgumentError) { agent_class { response_schema SCHEMA, name: "x" * 65 } }
    assert_raises(ArgumentError) { agent_class { response_schema "not a schema" } }
  end

  test "the schema reaches the provider only when declared" do
    assert_nil agent_class.new(system: "s", message: "hi").to_canonical_params[:response_schema]
    params = agent_class { response_schema SCHEMA, name: "r" }.new(system: "s", message: "hi").to_canonical_params
    assert_equal "r", params[:response_schema][:name]
  end

  test "a subclass inherits the schema and can replace it" do
    parent = agent_class { response_schema SCHEMA, name: "parent" }
    assert_equal "parent", Class.new(parent).new(system: "s", message: "hi").to_canonical_params[:response_schema][:name]
    child = Class.new(parent) { response_schema SCHEMA, name: "child" }
    assert_equal "child", child._response_schema[:name]
    assert_equal "parent", parent._response_schema[:name]
  end

  # ── complete_structured ──────────────────────────────────────────────────────

  test "complete_structured returns the parsed Hash" do
    agent = agent_class { response_schema SCHEMA }.new(system: "s", message: "hi")
    stub_ai_response(agent, response: '{"answer":"ok"}')
    assert_equal({ "answer" => "ok" }, agent.complete_structured)
  end

  test "complete_structured raises with the raw text when the answer is not JSON" do
    agent = agent_class { response_schema SCHEMA }.new(system: "s", message: "hi")
    stub_ai_response(agent, response: "Sure! Here you go.")
    error = assert_raises(ActiveAI::StructuredOutputError) { agent.complete_structured }
    assert_equal "Sure! Here you go.", error.raw
    assert_match "not valid JSON", error.message
  end

  test "complete_structured refuses JSON that is not an object" do
    agent = agent_class { response_schema SCHEMA }.new(system: "s", message: "hi")
    stub_ai_response(agent, response: "[1,2]")
    assert_raises(ActiveAI::StructuredOutputError) { agent.complete_structured }
  end

  test "complete_structured on an agent with no schema says so" do
    agent = agent_class.new(system: "s", message: "hi")
    stub_ai_response(agent, response: "{}")
    assert_raises(ActiveAI::ConfigurationError) { agent.complete_structured }
  end

  # ── provider_options ─────────────────────────────────────────────────────────

  test "provider_options are chosen by the resolved provider and omitted when empty" do
    klass = agent_class { provider_options openai: { reasoning_effort: "low" }, anthropic: { temperature: 0.2 } }
    assert_equal({ reasoning_effort: "low" }, klass.new(system: "s", message: "hi").to_canonical_params[:options])
    assert_equal({ temperature: 0.2 }, klass.new(system: "s", message: "hi", provider: :anthropic).to_canonical_params[:options])
    assert_not agent_class.new(system: "s", message: "hi").to_canonical_params.key?(:options)
  end

  test "provider_options merge across calls and inherit without leaking upward" do
    parent = agent_class { provider_options openai: { a: 1 } }
    child = Class.new(parent) { provider_options openai: { b: 2 } }
    assert_equal({ a: 1, b: 2 }, child.new(system: "s", message: "hi").to_canonical_params[:options])
    assert_equal({ a: 1 }, parent.new(system: "s", message: "hi").to_canonical_params[:options])
  end

  # ── per-call skills in every shape ───────────────────────────────────────────

  test "per-call skills accept a class, a string, a hash and an object" do
    PerCall = Struct.new(:id, :name, :content) unless defined?(PerCall)
    agent = WritingAgent.new(system: "s", message: "hi", skills: [
      ToneSkill, "Always answer in one sentence.", { name: "h", content: "from a hash" }, PerCall.new("i", "obj", "from an object")
    ])
    contents = agent.to_canonical_params[:skills].map { |skill| skill[:content] }
    assert_includes contents, ToneSkill.to_definition({})[:content]
    assert_includes contents, "Always answer in one sentence."
    assert_includes contents, "from a hash"
    assert_includes contents, "from an object"
  end

  # ── OpenAI wire format ───────────────────────────────────────────────────────

  def openai_sent(canonical_params)
    sent = nil
    provider = ActiveAI::Provider::OpenAI.new
    client = Object.new
    client.define_singleton_method(:chat) do |parameters:|
      sent = parameters
      { "choices" => [ { "message" => { "content" => '{"answer":"ok"}' } } ], "usage" => {} }
    end
    provider.instance_variable_set(:@client, client)
    provider.call(canonical_params)
    sent
  end

  test "OpenAI asks for json_schema, strict by default" do
    sent = openai_sent(canonical(response_schema: { name: "reply", schema: SCHEMA.deep_stringify_keys, strict: true }))
    assert_equal "json_schema", sent[:response_format][:type]
    assert_equal "reply", sent[:response_format][:json_schema][:name]
    assert_equal true, sent[:response_format][:json_schema][:strict]
    assert_equal SCHEMA.deep_stringify_keys, sent[:response_format][:json_schema][:schema]
  end

  test "OpenAI strict can be turned off and a description is passed along" do
    sent = openai_sent(canonical(response_schema: { name: "reply", schema: {}, strict: false, description: "A reply." }))
    assert_equal false, sent[:response_format][:json_schema][:strict]
    assert_equal "A reply.", sent[:response_format][:json_schema][:description]
  end

  test "OpenAI sends no response_format without a schema" do
    assert_not openai_sent(canonical).key?(:response_format)
  end

  test "OpenAI provider_options are added, and nil removes a default" do
    sent = openai_sent(canonical(options: { reasoning_effort: "low", max_completion_tokens: nil }))
    assert_equal "low", sent[:reasoning_effort]
    assert_not sent.key?(:max_completion_tokens)
  end

  test "an OpenAI refusal is an error, not an empty answer (blocking)" do
    provider = ActiveAI::Provider::OpenAI.new
    client = Object.new
    client.define_singleton_method(:chat) { |parameters:| { "choices" => [ { "message" => { "content" => nil, "refusal" => "I can't help with that." } } ], "usage" => {} } }
    provider.instance_variable_set(:@client, client)
    error = assert_raises(ActiveAI::ProviderError) { provider.call(canonical) }
    assert_match "declined to answer: I can't help with that.", error.message
    assert_equal "refusal", error.type
  end

  test "an OpenAI refusal is an error, not an empty answer (streaming)" do
    provider = ActiveAI::Provider::OpenAI.new
    client = Object.new
    client.define_singleton_method(:chat) do |parameters:|
      [ "I can't ", "help with that." ].each { |piece| parameters[:stream].call({ "choices" => [ { "delta" => { "refusal" => piece } } ] }, nil) }
    end
    provider.instance_variable_set(:@client, client)
    error = assert_raises(ActiveAI::ProviderError) { provider.stream(canonical) { } }
    assert_match "I can't help with that.", error.message
  end

  test "streamed text with no refusal is untouched" do
    provider = ActiveAI::Provider::OpenAI.new
    client = Object.new
    client.define_singleton_method(:chat) { |parameters:| parameters[:stream].call({ "choices" => [ { "delta" => { "content" => "ok" } } ] }, nil) }
    provider.instance_variable_set(:@client, client)
    chunks = []
    provider.stream(canonical) { |chunk| chunks << chunk }
    assert_equal [ "ok" ], chunks
  end

  # ── Anthropic wire format ────────────────────────────────────────────────────

  Block = Struct.new(:type, :name, :input, :id)
  Usage = Struct.new(:input_tokens, :output_tokens)
  Message = Struct.new(:content, :stop_reason, :usage, :id)

  def anthropic_provider(message, capture: nil)
    provider = ActiveAI::Provider::Anthropic.new
    messages = Object.new
    messages.define_singleton_method(:create) { |**params| capture&.call(params); message }
    messages.define_singleton_method(:stream) do |**params|
      capture&.call(params)
      stream = Object.new
      stream.define_singleton_method(:text) { [].each }
      stream.define_singleton_method(:accumulated_message) { message }
      stream
    end
    client = Object.new
    client.define_singleton_method(:messages) { messages }
    provider.instance_variable_set(:@client, client)
    provider
  end

  def answer_message(input: { "answer" => "ok" }, stop_reason: "tool_use")
    Message.new([ Block.new(:tool_use, "reply", input, "tu_1") ], stop_reason, Usage.new(10, 5), "msg_1")
  end

  def schema_params = canonical(response_schema: { name: "reply", schema: SCHEMA.deep_stringify_keys })

  test "Anthropic forces a single tool whose input schema is the response schema" do
    sent = nil
    anthropic_provider(answer_message, capture: ->(params) { sent = params }).call(schema_params)
    assert_equal [ "reply" ], sent[:tools].map { |tool| tool[:name] }
    assert_equal SCHEMA.deep_stringify_keys, sent[:tools].first[:input_schema]
    assert_equal({ type: "tool", name: "reply" }, sent[:tool_choice])
  end

  test "Anthropic returns the forced tool's input as JSON text (blocking)" do
    assert_equal({ "answer" => "ok" }, JSON.parse(anthropic_provider(answer_message).call(schema_params)))
  end

  test "Anthropic returns the forced tool's input as JSON text, and reports no tool calls (streaming)" do
    provider = anthropic_provider(answer_message)
    chunks = []
    provider.stream(schema_params) { |chunk| chunks << chunk }
    assert_equal [ { "answer" => "ok" } ], chunks.map { |chunk| JSON.parse(chunk) }
    assert_empty provider.last_tool_calls, "the forced schema tool is the answer, not a tool for the loop to run"
    assert_empty provider.last_assistant_content
  end

  test "Anthropic parses tool input that arrives as a JSON string, as streaming delivers it" do
    provider = anthropic_provider(answer_message(input: '{"answer":"from a string"}'))
    assert_equal({ "answer" => "from a string" }, JSON.parse(provider.call(schema_params)))
  end

  test "a cut-off structured answer is an error that says to raise max_tokens" do
    error = assert_raises(ActiveAI::ProviderError) { anthropic_provider(answer_message(stop_reason: "max_tokens")).call(schema_params) }
    assert_match "max_tokens", error.message
  end

  test "a response with no schema tool block is an error" do
    empty = Message.new([ Block.new(:text, nil, nil, nil) ], "end_turn", Usage.new(1, 1), "m")
    assert_raises(ActiveAI::ProviderError) { anthropic_provider(empty).call(schema_params) }
  end

  test "a schema cannot be combined with real tools on Anthropic" do
    error = assert_raises(ActiveAI::ConfigurationError) do
      anthropic_provider(answer_message).call(schema_params.merge(tools: [ { name: "t", description: "d", input_schema: {} } ]))
    end
    assert_match "cannot be combined with tools", error.message
  end

  test "Anthropic sends no tool_choice without a schema, and provider_options pass through" do
    sent = nil
    plain = Message.new([ Block.new(:text, nil, nil, nil) ], "end_turn", Usage.new(1, 1), "m")
    plain.content.first.define_singleton_method(:text) { "hello" }
    anthropic_provider(plain, capture: ->(params) { sent = params }).call(canonical(options: { temperature: 0.2, metadata: { user_id: "u" } }))
    assert_not sent.key?(:tool_choice)
    assert_equal 0.2, sent[:temperature]
    assert_equal({ user_id: "u" }, sent[:metadata])
  end
end
