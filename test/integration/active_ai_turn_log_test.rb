require "test_helper"

class TurnLogLookup < ApplicationTool
  tool_name "lookup"
  description "Looks something up"
  def call(**) = "the notes say: ship on Friday"
end

# Everything an agent says is kept, turn by turn: published as it happens, returned on the Response, and (on OpenAI) shown
# back to the model on its next turn. Both real providers run here with only the HTTP client faked.
class ActiveAITurnLogTest < ActiveSupport::TestCase
  NARRATION = "Let me check the notes for you. ".freeze
  ANSWER = "We ship on Friday.".freeze

  # ── OpenAI: fake the chat client, replay streaming chunks ──────────────────
  def openai_text(text) = [ { "id" => "c", "choices" => [ { "delta" => { "content" => text }, "finish_reason" => nil } ], "usage" => nil } ]
  def openai_stop = [ { "id" => "c", "choices" => [ { "delta" => {}, "finish_reason" => "stop" } ], "usage" => nil }, { "id" => "c", "choices" => [], "usage" => { "prompt_tokens" => 20, "completion_tokens" => 6 } } ]
  def openai_tool = [
    { "id" => "c", "choices" => [ { "delta" => { "tool_calls" => [ { "index" => 0, "id" => "call_1", "type" => "function", "function" => { "name" => "lookup", "arguments" => "{}" } } ] }, "finish_reason" => nil } ], "usage" => nil },
    { "id" => "c", "choices" => [ { "delta" => {}, "finish_reason" => "tool_calls" } ], "usage" => nil },
    { "id" => "c", "choices" => [], "usage" => { "prompt_tokens" => 10, "completion_tokens" => 5 } } ]

  # `turns` is a list of chunk lists, or an error to raise (after delivering its chunks first, as a dropped connection would).
  def openai_agent(turns, narration: NARRATION)
    provider = ActiveAI::Provider::OpenAI.new
    sent = []
    calls = 0
    fake = Object.new
    fake.define_singleton_method(:chat) do |parameters:|
      sent << parameters[:messages].map(&:dup)
      chunks, failure = turns.fetch(calls)
      calls += 1
      chunks.each { |chunk| parameters[:stream].call(chunk, nil) }
      raise failure if failure
    end
    provider.instance_variable_set(:@client, fake)
    agent = Class.new(WritingAgent) { tools TurnLogLookup }.new(system: "s", message: "when do we ship?")
    agent.define_singleton_method(:provider_instance) { provider }
    [ agent, sent ]
  end

  def narrated_turns = [ [ openai_text(NARRATION) + openai_tool, nil ], [ openai_text(ANSWER) + openai_stop, nil ] ]

  # ── Anthropic: fake the messages stream ────────────────────────────────────
  Block = Struct.new(:type, :text, :id, :name, :input, keyword_init: true)
  Usage = Struct.new(:input_tokens, :output_tokens, :cache_creation_input_tokens, :cache_read_input_tokens, keyword_init: true)
  Message = Struct.new(:id, :model, :stop_reason, :content, :usage, keyword_init: true)
  FakeStream = Struct.new(:deltas, :accumulated_message) { def text = deltas.each }

  def anthropic_agent
    usage = ->(input, output) { Usage.new(input_tokens: input, output_tokens: output, cache_creation_input_tokens: 0, cache_read_input_tokens: 0) }
    turns = [
      FakeStream.new([ NARRATION ], Message.new(id: "m1", model: "claude-x", stop_reason: :tool_use, usage: usage.(10, 5),
        content: [ Block.new(type: :text, text: NARRATION), Block.new(type: :tool_use, id: "tu_1", name: "lookup", input: "{}") ])),
      FakeStream.new([ ANSWER ], Message.new(id: "m2", model: "claude-x", stop_reason: :end_turn, usage: usage.(20, 6),
        content: [ Block.new(type: :text, text: ANSWER) ]))
    ]
    provider = ActiveAI::Provider::Anthropic.new
    sent = []
    calls = 0
    api = Object.new
    api.define_singleton_method(:stream) { |**params| sent << params[:messages].map(&:dup); turns.fetch((calls += 1) - 1) }
    client = Object.new
    client.define_singleton_method(:messages) { api }
    provider.instance_variable_set(:@client, client)
    agent = Class.new(WritingAgent) { tools TurnLogLookup }.new(system: "s", message: "when do we ship?")
    agent.define_singleton_method(:provider_instance) { provider }
    [ agent, sent ]
  end

  def events_while(names = %w[agent_turn.active_ai])
    seen = []
    subscriptions = names.map { |name| ActiveSupport::Notifications.subscribe(name) { |event_name, _s, _f, _id, payload| seen << [ event_name, payload.dup ] } }
    yield
    seen
  ensure
    subscriptions.each { |subscription| ActiveSupport::Notifications.unsubscribe(subscription) }
  end

  test "each turn is published on its own with its own words, tools and tokens (OpenAI)" do
    agent, = openai_agent(narrated_turns)
    turns = events_while { agent.complete }.map(&:last)
    assert_equal [ 1, 2 ], turns.map { |turn| turn[:turn] }
    assert_equal [ NARRATION, ANSWER ], turns.map { |turn| turn[:text] }
    assert_equal [ [ "lookup" ], [] ], turns.map { |turn| turn[:tool_calls].map { |call| call[:name] } }
    assert_equal [ [ 10, 5 ], [ 20, 6 ] ], turns.map { |turn| turn[:usage].values_at(:input_tokens, :output_tokens) }
    assert_equal [ false, true ], turns.map { |turn| turn[:final] }
    assert turns.none? { |turn| turn[:interrupted] }
  end

  test "each turn is published on its own with its own words, tools and tokens (Anthropic)" do
    agent, = anthropic_agent
    turns = events_while { agent.complete }.map(&:last)
    assert_equal [ NARRATION, ANSWER ], turns.map { |turn| turn[:text] }
    assert_equal [ [ "lookup" ], [] ], turns.map { |turn| turn[:tool_calls].map { |call| call[:name] } }
    assert_equal [ [ 10, 5 ], [ 20, 6 ] ], turns.map { |turn| turn[:usage].values_at(:input_tokens, :output_tokens) }
  end

  test "a turn is filed before its tool runs, so a failing tool can't lose what was said" do
    agent, = openai_agent(narrated_turns)
    order = events_while(%w[agent_turn.active_ai tool_call.active_ai]) { agent.complete }.map(&:first)
    assert_equal %w[agent_turn.active_ai tool_call.active_ai agent_turn.active_ai], order
  end

  test "the Response keeps the turns apart, and its text is still all of them joined" do
    [ openai_agent(narrated_turns).first, anthropic_agent.first ].each do |agent|
      response = agent.generate
      assert_equal NARRATION + ANSWER, response.text
      assert_equal [ NARRATION, ANSWER ], response.turn_log.map { |turn| turn[:text] }
      assert_equal response.turns, response.turn_log.size
      assert_equal response.usage[:input_tokens], response.turn_log.sum { |turn| turn[:usage][:input_tokens] }
      assert_equal [ NARRATION, ANSWER ], response.as_json["turn_log"].map { |turn| turn["text"] }
    end
  end

  test "when a later call breaks, what was already said survives, including a half-finished answer" do
    broken = [ [ openai_text(NARRATION) + openai_tool, nil ], [ openai_text("We ship on Fri"), Faraday::ConnectionFailed.new("connection lost") ] ]
    agent, = openai_agent(broken)
    events = events_while { assert_raises(ActiveAI::ProviderError) { agent.complete } }.map(&:last)
    assert_equal [ NARRATION, "We ship on Fri" ], events.map { |turn| turn[:text] }
    assert_equal [ false, true ], events.map { |turn| turn[:interrupted] }
    assert_equal [ NARRATION, "We ship on Fri" ], agent.turn_log.map { |turn| turn[:text] }
    assert_nil events.last[:usage]
  end

  test "OpenAI is shown what it said before the tool call, so it doesn't start over" do
    agent, sent = openai_agent(narrated_turns)
    agent.complete
    assistant = sent.last.find { |message| message[:role] == "assistant" }
    assert_equal NARRATION, assistant[:content]
    assert_equal "lookup", assistant[:tool_calls].first.dig("function", "name")
  end

  test "OpenAI with nothing said before the tool call still sends no content, as before" do
    agent, sent = openai_agent(narrated_turns.tap { |turns| turns[0] = [ openai_tool, nil ] })
    agent.complete
    assert_nil sent.last.find { |message| message[:role] == "assistant" }[:content]
  end

  test "Anthropic is shown what it said before the tool call" do
    agent, sent = anthropic_agent
    agent.complete
    assistant = sent.last.find { |message| message[:role] == "assistant" }
    assert_equal NARRATION, assistant[:content].first[:text]
  end

  test "call_context travels with every turn" do
    agent, = openai_agent(narrated_turns)
    agent.define_singleton_method(:call_context) { { run: 7 } }
    assert_equal [ { run: 7 }, { run: 7 } ], events_while { agent.complete }.map { |_, payload| payload[:context] }
  end

  test "a Response built without a turn_log, as before, still works and has an empty one" do
    response = build_ai_response_without_log
    assert_equal [], response.turn_log
  end

  def build_ai_response_without_log
    ActiveAI::Response.new(text: "x", data: nil, data_error: nil, provider: :test, requested_model: "m", model: "m", finish_reason: :complete,
                           raw_finish_reason: "stop", refusal: nil, usage: nil, turns: 1, request_id: nil, tool_calls: [], latency: 0.1,
                           start_time: Time.now.utc, end_time: Time.now.utc)
  end
end
