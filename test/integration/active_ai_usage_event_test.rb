require "test_helper"

# agent_usage.active_ai is how an app learns every token a call spent, including calls whose answer it threw away.
# All tests stub the provider; no real API calls are made.
class UsageEventPing < ApplicationTool
  tool_name "ping_usage_test"
  description "Pings"
  def call(**) = "pong"
end

class ActiveAIUsageEventTest < ActiveSupport::TestCase
  include ActiveAI::TestHelper

  USAGE = ->(input, output, extra = {}) { { input_tokens: input, output_tokens: output, cache_read_tokens: 0, reasoning_tokens: nil }.merge(extra) }

  # Each turn is { usage:, response: "text" } or, to ask for a tool, { usage:, tool_calls: [...] }, or { raises: error }.
  def stub_turns(agent, turns)
    calls = 0
    agent.define_singleton_method(:provider_instance) do
      turn = turns.fetch([ calls, turns.size - 1 ].min)
      calls += 1
      prov = Object.new
      if turn[:raises]
        prov.define_singleton_method(:stream) { |_params, &_block| raise turn[:raises] }
        prov.define_singleton_method(:last_usage) { nil }
      else
        tool_calls = turn[:tool_calls] || []
        prov.define_singleton_method(:stream) { |_params, &block| block.call(turn[:response].to_s) unless tool_calls.any? }
        prov.define_singleton_method(:last_usage) { turn[:usage] }
      end
      tool_calls = turn[:tool_calls] || []
      prov.define_singleton_method(:last_tool_calls) { tool_calls }
      prov.define_singleton_method(:last_assistant_content) { tool_calls.map { |tc| { type: "tool_use", id: tc[:id], name: tc[:name], input: tc[:input] } } }
      prov.define_singleton_method(:format_assistant_turn) { |content, _| { role: "assistant", content: content } }
      prov.define_singleton_method(:format_tool_result_messages) { |results| [ { role: "user", content: results } ] }
      prov
    end
  end

  def usage_events
    events = []
    subscription = ActiveSupport::Notifications.subscribe("agent_usage.active_ai") { |_name, _start, _finish, _id, payload| events << payload.dup }
    yield
    events
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end

  test "one call reports its tokens once, with who and what it was" do
    agent = WritingAgent.new(system: "test", message: "go")
    stub_turns(agent, [ { usage: USAGE.(120, 30), response: "hello" } ])
    events = usage_events { agent.complete }
    assert_equal 1, events.size
    event = events.first
    assert_equal "WritingAgent", event[:agent_class]
    assert_equal [ 120, 30 ], event[:usage].values_at(:input_tokens, :output_tokens)
    assert_equal 1, event[:turns]
    assert event[:completed]
    assert_equal({}, event[:context])
  end

  test "an agent can say whose call it is, and the answer travels with the event" do
    agent_class = Class.new(WritingAgent) { def call_context = { user_id: 42 } }
    agent = agent_class.new(system: "test", message: "go")
    stub_turns(agent, [ { usage: USAGE.(1, 1), response: "x" } ])
    assert_equal({ user_id: 42 }, usage_events { agent.complete }.first[:context])
  end

  test "a tool loop reports every turn added together, not just the last" do
    agent = Class.new(WritingAgent) { tools(UsageEventPing) }.new(system: "test", message: "go")
    stub_turns(agent, [
      { usage: USAGE.(100, 20, reasoning_tokens: 5), tool_calls: [ { id: "t1", name: "ping_usage_test", input: {} } ] },
      { usage: USAGE.(150, 40, reasoning_tokens: 7), response: "done" }
    ])
    event = usage_events { agent.complete }.first
    assert_equal [ 250, 60, 12 ], event[:usage].values_at(:input_tokens, :output_tokens, :reasoning_tokens)
    assert_equal 2, event[:turns]
    assert_equal [ [ 100, 20 ], [ 150, 40 ] ], event[:per_turn].map { |turn| turn.values_at(:input_tokens, :output_tokens) }
  end

  test "tokens a call spent before it failed are still reported, and the failure still raises" do
    agent = Class.new(WritingAgent) { tools(UsageEventPing) }.new(system: "test", message: "go")
    stub_turns(agent, [
      { usage: USAGE.(100, 20), tool_calls: [ { id: "t1", name: "ping_usage_test", input: {} } ] },
      { raises: ActiveAI::ProviderError.new("the provider went away") }
    ])
    events = usage_events { assert_raises(ActiveAI::ProviderError) { agent.complete } }
    assert_equal 1, events.size
    assert_equal [ 100, 20 ], events.first[:usage].values_at(:input_tokens, :output_tokens)
    assert_not events.first[:completed]
  end

  test "generate reports the same tokens its Response does, once" do
    agent = WritingAgent.new(system: "test", message: "go")
    stub_turns(agent, [ { usage: USAGE.(80, 25), response: "ok" } ])
    response = nil
    events = usage_events { response = agent.generate }
    assert_equal 1, events.size
    assert_equal response.usage[:input_tokens], events.first[:usage][:input_tokens]
    assert_equal response.usage[:output_tokens], events.first[:usage][:output_tokens]
  end

  test "a call the provider never reported usage for says nothing, rather than reporting zero" do
    agent = WritingAgent.new(system: "test", message: "go")
    stub_turns(agent, [ { usage: nil, response: "hello" } ])
    assert_empty usage_events { agent.complete }
  end

  test "two calls on the same agent each report their own tokens" do
    agent = WritingAgent.new(system: "test", message: "go")
    stub_turns(agent, [ { usage: USAGE.(10, 5), response: "a" }, { usage: USAGE.(30, 9), response: "b" } ])
    events = usage_events { 2.times { agent.complete } }
    assert_equal [ [ 10, 5 ], [ 30, 9 ] ], events.map { |event| event[:usage].values_at(:input_tokens, :output_tokens) }
  end
end
