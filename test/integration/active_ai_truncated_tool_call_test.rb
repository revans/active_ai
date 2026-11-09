require "test_helper"

# A tool call cut off at the token limit is not run with empty arguments: the stream raises OutputTruncatedError, which says what happened.
class ActiveAITruncatedToolCallTest < ActiveSupport::TestCase
  def provider_finishing(reason, tool_calls)
    provider = Object.new
    provider.define_singleton_method(:stream) { |_params, &_block| nil }
    provider.define_singleton_method(:last_tool_calls) { tool_calls }
    provider.define_singleton_method(:last_usage) { nil }
    provider.define_singleton_method(:last_assistant_content) { [] }
    provider.define_singleton_method(:last_finish_reason) { reason }
    provider.define_singleton_method(:last_raw_finish_reason) { reason == :truncated ? "max_tokens" : "end_turn" }
    provider
  end

  def agent_with(provider)
    agent = Class.new(ActiveAI::Agent::Base) { model "claude-sonnet-4-6" }.new
    agent.define_singleton_method(:provider_instance) { provider }
    agent.define_singleton_method(:build_params) { { model: "claude-sonnet-4-6", max_tokens: 10, system: "s", messages: [ { role: "user", content: "go" } ], tools: [] } }
    agent
  end

  test "a tool call cut off at the token limit raises, naming the limit, and the tool is not run" do
    agent = agent_with(provider_finishing(:truncated, [ { id: "t1", name: "x", input: {} } ]))
    error = assert_raises(ActiveAI::OutputTruncatedError) { agent.stream { } }
    assert_match(/output limit.*max_tokens/m, error.message)
  end

  test "a text answer that stops at the limit is not an error here, and last_finish_reason says so" do
    agent = agent_with(provider_finishing(:truncated, []))
    agent.stream { }
    assert_equal :truncated, agent.last_finish_reason
  end
end
