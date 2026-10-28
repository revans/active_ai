require "test_helper"

# A prompt, the model's answer and every log line around them share ActiveAI's own ids, minted before anything is
# sent — so a call that never got an answer is still tied to the prompt that went out for it.
class ActiveAITraceIdsTest < ActiveSupport::TestCase
  class TraceLookup < ApplicationTool
    tool_name "lookup"
    description "Looks something up"
    def call(**) = "ship on Friday"
  end

  class TraceWorkflow < ActiveAI::Workflow::Base
    def run(input) = parallel_step([TraceLookup, {}], [TraceLookup, {}])
  end

  def text_chunks(text) = [ { "id" => "chatcmpl-1", "choices" => [ { "delta" => { "content" => text }, "finish_reason" => nil } ], "usage" => nil } ]
  def stop_chunks = [ { "id" => "chatcmpl-1", "choices" => [ { "delta" => {}, "finish_reason" => "stop" } ], "usage" => nil },
                      { "id" => "chatcmpl-1", "choices" => [], "usage" => { "prompt_tokens" => 20, "completion_tokens" => 6 } } ]
  def tool_chunks = [
    { "id" => "chatcmpl-0", "choices" => [ { "delta" => { "tool_calls" => [ { "index" => 0, "id" => "call_1", "type" => "function", "function" => { "name" => "lookup", "arguments" => "{}" } } ] }, "finish_reason" => nil } ], "usage" => nil },
    { "id" => "chatcmpl-0", "choices" => [ { "delta" => {}, "finish_reason" => "tool_calls" } ], "usage" => nil },
    { "id" => "chatcmpl-0", "choices" => [], "usage" => { "prompt_tokens" => 10, "completion_tokens" => 5 } } ]

  # `turns` is a list of [chunks, error-to-raise-after-them].
  def agent_with(turns)
    provider = ActiveAI::Provider::OpenAI.new
    calls = 0
    fake = Object.new
    fake.define_singleton_method(:chat) do |parameters:|
      chunks, failure = turns.fetch(calls)
      calls += 1
      chunks.each { |chunk| parameters[:stream].call(chunk, nil) }
      raise failure if failure
    end
    provider.instance_variable_set(:@client, fake)
    agent = Class.new(WritingAgent) { tools TraceLookup }.new(system: "s", message: "when do we ship?")
    agent.define_singleton_method(:provider_instance) { provider }
    agent
  end

  test "each prompt and its answer share a span, and the run id ties them to the response and every event" do
    agent = nil
    events = capture(%w[agent_request agent_turn tool_call agent_complete agent_usage]) do
      agent = agent_with([ [ tool_chunks, nil ], [ text_chunks("Friday.") + stop_chunks, nil ] ])
      agent.generate
    end

    run_id = agent.last_response.run_id
    assert_match(/\A\h{8}-\h{4}-/, run_id)
    assert events.all? { |_, payload| payload[:run_id] == run_id }, "every event must carry the run id"

    requests = events.select { |name, _| name == "agent_request" }.map(&:last)
    turns    = events.select { |name, _| name == "agent_turn" }.map(&:last)
    assert_equal requests.map { |r| r[:span_id] }, turns.map { |t| t[:span_id] }
    assert_equal 2, requests.map { |r| r[:span_id] }.uniq.size, "each provider call has its own span"
    assert_equal turns.map { |t| t[:span_id] }, agent.last_response.turn_log.map { |t| t[:span_id] }
    assert_equal [run_id], agent.last_response.turn_log.map { |t| t[:run_id] }.uniq
    assert_equal "when do we ship?", requests.first[:messages].last[:content]

    complete = events.find { |name, _| name == "agent_complete" }.last
    tool     = events.find { |name, _| name == "tool_call" }.last
    assert_equal complete[:span_id], requests.first[:parent_span_id], "the provider call hangs off the agent's span"
    assert_equal complete[:span_id], tool[:parent_span_id], "the tool hangs off the agent's span"
  end

  test "a provider call that fails is filed under the span its prompt went out with" do
    agent = agent_with([ [ [], Faraday::TimeoutError.new("timed out") ] ])
    events = capture(%w[agent_request agent_turn]) do
      assert_raises(ActiveAI::ProviderError) { agent.complete }
    end

    request, turn = events.map(&:last)
    assert_equal request[:span_id], turn[:span_id]
    assert_match(/timed out/, turn[:error])
    assert_nil turn[:provider_request_id]
    assert_equal request[:span_id], agent.turn_log.last[:span_id]
  end

  test "separate top-level calls get separate runs; an id of your own is used when given" do
    first  = capture(%w[tool_call]) { TraceLookup.new.call }.last.last[:run_id]
    second = capture(%w[tool_call]) { TraceLookup.new.call }.last.last[:run_id]
    mine   = capture(%w[tool_call]) { ActiveAI::Instrumentation.with_run(run_id: "mine") { TraceLookup.new.call } }.last.last

    assert_not_equal first, second
    assert_equal "mine", mine[:run_id]
  end

  test "parallel steps stay in the workflow's run, each under the workflow's span" do
    events = capture(%w[workflow_run tool_call]) { TraceWorkflow.run("x") }
    workflow = events.find { |name, _| name == "workflow_run" }.last
    tools    = events.select { |name, _| name == "tool_call" }.map(&:last)

    assert_equal 2, tools.size
    assert tools.all? { |t| t[:run_id] == workflow[:run_id] && t[:parent_span_id] == workflow[:span_id] }
  end

  test "a run inside a Rails request or job records its id beside the run id" do
    request    = Struct.new(:request_id).new("req-123")
    controller = Struct.new(:request).new(request)
    ActiveSupport::ExecutionContext[:controller] = controller
    payload = capture(%w[tool_call]) { TraceLookup.new.call }.last.last

    assert_equal "req-123", payload[:request_id]
    assert_not_equal "req-123", payload[:run_id]
  ensure
    ActiveSupport::ExecutionContext.clear
  end

  test "every log line carries the run and span" do
    output = StringIO.new
    previous, ActiveSupport::LogSubscriber.logger = ActiveSupport::LogSubscriber.logger, ActiveSupport::Logger.new(output)
    ActiveAI::Instrumentation.with_run(run_id: "run-1") { TraceLookup.new.call }

    assert_match(/ActiveAI tool.*lookup .* run=run-1 span=\h{8}-/, output.string)
  ensure
    ActiveSupport::LogSubscriber.logger = previous
  end

  private

  def capture(names, &)
    events      = []
    subscribers = names.map do |name|
      ActiveSupport::Notifications.subscribe("#{name}.active_ai") { |*, payload| events << [name, payload] }
    end
    yield
    events
  ensure
    subscribers.each { |subscriber| ActiveSupport::Notifications.unsubscribe(subscriber) }
  end
end
