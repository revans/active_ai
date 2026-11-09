require "test_helper"

# stream(tool_progress: true): while the model is still writing a tool call, the block hears { tool_started: } and { tool_progress: }. Off by
# default, so a block written before these events existed sees only Strings and { tool_call: } hashes.
class ActiveAIToolProgressTest < ActiveSupport::TestCase
  Block = Struct.new(:type, :id, :name)
  Delta = Struct.new(:type, :text, :partial_json)
  Event = Struct.new(:type, :index, :content_block, :delta)

  def canonical(extra = {})
    { model: "claude-sonnet-4-6", max_tokens: 1024, system: "s", skills: [], source_files: [], messages: [ { role: "user", content: "go" } ], cacheable: {}, tools: [] }.merge(extra)
  end

  # A fake Anthropic message stream: `each` gives the raw events, `text` only the text deltas, as the SDK does.
  def fake_stream(events)
    stream = Object.new
    stream.define_singleton_method(:each) { |&block| events.each(&block) }
    stream.define_singleton_method(:text) { events.filter_map { |e| e.delta.text if e.type == :content_block_delta && e.delta.type == :text_delta } }
    stream.define_singleton_method(:accumulated_message) { {} }
    stream
  end

  def anthropic_with(events)
    provider = ActiveAI::Provider::Anthropic.new
    messages = Object.new
    stream = fake_stream(events)
    messages.define_singleton_method(:stream) { |**_| stream }
    client = Object.new
    client.define_singleton_method(:messages) { messages }
    provider.instance_variable_set(:@client, client)
    provider
  end

  def anthropic_events
    [
      Event.new(:content_block_start, 0, Block.new(:text, nil, nil), nil),
      Event.new(:content_block_delta, 0, nil, Delta.new(:text_delta, "Saving ", nil)),
      Event.new(:content_block_start, 1, Block.new(:tool_use, "toolu_1", "update_discovery_brief"), nil),
      Event.new(:content_block_delta, 1, nil, Delta.new(:input_json_delta, nil, "{\"text\":\"# Br")),
      Event.new(:content_block_delta, 1, nil, Delta.new(:input_json_delta, nil, "ief\"}")),
      Event.new(:content_block_stop, 1, nil, nil)
    ]
  end

  test "Anthropic: with tool_progress the block hears the tool begin and its input arrive, and text as before" do
    heard = []
    anthropic_with(anthropic_events).stream(canonical(tool_progress: true)) { |event| heard << event }
    assert_equal [
      "Saving ",
      { tool_started: { id: "toolu_1", name: "update_discovery_brief" } },
      { tool_progress: { id: "toolu_1", name: "update_discovery_brief", characters: 13 } },
      { tool_progress: { id: "toolu_1", name: "update_discovery_brief", characters: 18 } }
    ], heard
  end

  test "Anthropic: without tool_progress only the text comes through" do
    heard = []
    anthropic_with(anthropic_events).stream(canonical) { |event| heard << event }
    assert_equal [ "Saving " ], heard
  end

  def chat_with(chunks)
    provider = ActiveAI::Provider::OpenAI.new
    client = Object.new
    client.define_singleton_method(:chat) { |parameters:| chunks.each { |chunk| parameters[:stream].call(chunk, nil) } }
    provider.instance_variable_set(:@client, client)
    provider
  end

  def openai_chunks
    [
      { "choices" => [ { "delta" => { "tool_calls" => [ { "index" => 0, "id" => "call_1", "type" => "function", "function" => { "name" => "update_discovery_brief", "arguments" => "" } } ] }, "finish_reason" => nil } ] },
      { "choices" => [ { "delta" => { "tool_calls" => [ { "index" => 0, "function" => { "arguments" => "{\"text\":" } } ] }, "finish_reason" => nil } ] },
      { "choices" => [ { "delta" => { "tool_calls" => [ { "index" => 0, "function" => { "arguments" => "\"x\"}" } } ] }, "finish_reason" => nil } ] },
      { "choices" => [ { "delta" => {}, "finish_reason" => "tool_calls" } ] }
    ]
  end

  test "OpenAI: with tool_progress the block hears the call begin and its arguments arrive" do
    heard = []
    provider = chat_with(openai_chunks)
    provider.stream(canonical(model: "gpt-4.1", tool_progress: true)) { |event| heard << event }
    assert_equal({ tool_started: { id: "call_1", name: "update_discovery_brief" } }, heard.first)
    assert_equal [ 8, 12 ], heard.drop(1).map { |event| event[:tool_progress][:characters] }
    assert_equal [ { id: "call_1", name: "update_discovery_brief", input: { "text" => "x" } } ], provider.last_tool_calls
  end

  test "OpenAI: without tool_progress the block hears nothing for a tool call" do
    heard = []
    chat_with(openai_chunks).stream(canonical(model: "gpt-4.1")) { |event| heard << event }
    assert_empty heard
  end

  test "Agent#stream passes the flag to the provider only when asked" do
    seen = []
    provider = Object.new
    provider.define_singleton_method(:stream) { |params, &block| seen << params[:tool_progress] }
    provider.define_singleton_method(:last_tool_calls) { [] }
    provider.define_singleton_method(:last_usage) { nil }
    provider.define_singleton_method(:last_assistant_content) { [] }
    agent_class = Class.new(ActiveAI::Agent::Base) { model "claude-sonnet-4-6" }
    agent = agent_class.new
    agent.define_singleton_method(:provider_instance) { provider }
    agent.define_singleton_method(:build_params) { { model: "claude-sonnet-4-6", max_tokens: 10, system: "s", messages: [ { role: "user", content: "go" } ], tools: [] } }
    agent.stream { }
    agent.stream(tool_progress: true) { }
    assert_equal [ nil, true ], seen
  end
end
