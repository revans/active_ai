require "test_helper"
require "support/fake_openai_agent"

# A prompt, the model's answer and every log line around them share ActiveAI's own ids, minted before anything is
# sent — so a call that never got an answer is still tied to the prompt that went out for it.
class ActiveAITraceIdsTest < ActiveSupport::TestCase
  TraceLookup = FakeOpenAIAgent::Lookup

  class TraceWorkflow < ActiveAI::Workflow::Base
    def run(input) = parallel_step([TraceLookup, {}], [TraceLookup, {}])
  end

  def agent_with(turns) = FakeOpenAIAgent.build(turns).first

  test "each prompt and its answer share a span, and the run id ties them to the response and every event" do
    agent = nil
    events = capture(%w[agent_request agent_turn tool_call agent_complete agent_usage]) do
      agent = agent_with(FakeOpenAIAgent.tool_then_answer)
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
    assert_equal agent.send(:build_params).except(:messages), requests.first.slice(*agent.send(:build_params).except(:messages).keys),
                 "the request event carries every setting ActiveAI hands the provider"
    assert_equal ["lookup"], requests.first[:tools].map { |tool| tool[:name] }
    assert_not requests.last.key?(:system), "settings go out once per stream, on its first request"
    assert_equal requests.first[:messages].size, requests.last[:messages_before]
    assert_equal %w[assistant tool], requests.last[:messages].map { |m| m[:role].to_s }, "a later request carries only what is new"

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
