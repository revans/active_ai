require "test_helper"

# Every component fires its event however it is invoked — not only from inside an agent loop.
class ActiveAIInstrumentationCoverageTest < ActiveSupport::TestCase
  class EchoTool < ActiveAI::Tool::Base
    tool_name "echo"
    description "Echoes its input"
    param :text, type: :string, description: "Text"

    def call(text:) = "echo #{text}"
  end

  class LoudEchoTool < EchoTool
    def call(text:) = super.upcase
  end

  class EchoWorkflow < ActiveAI::Workflow::Base
    def run(input) = "ran #{input}"
  end

  class ParallelWorkflow < ActiveAI::Workflow::Base
    def run(input)
      parallel_step([EchoTool, { text: input }], [EchoTool, { text: input }])
    end
  end

  class PingCommand < ActiveAI::Command::Base
    command_name "ping"
    description "Ping"
    trigger phrase: "/ping"
    response_type :json

    def call(argument: nil) = "pong #{argument}"
  end

  test "a tool called directly fires tool_call.active_ai with its result" do
    events = capture("tool_call.active_ai") { assert_equal "echo hi", EchoTool.new.call(text: "hi") }

    assert_equal 1, events.size
    assert_equal({ tool_name: "echo", tool_class: EchoTool.name, result: "echo hi" },
                 events.first.slice(:tool_name, :tool_class, :result))
  end

  test "a tool subclass that calls super fires one event, not one per level" do
    events = capture("tool_call.active_ai") { assert_equal "ECHO HI", LoudEchoTool.call(text: "hi") }

    assert_equal [LoudEchoTool.name], events.map { |e| e[:tool_class] }
  end

  test "a workflow fires workflow_run.active_ai through new.run as well as Workflow.run" do
    assert_equal 1, capture("workflow_run.active_ai") { EchoWorkflow.new.run("x") }.size
    assert_equal 1, capture("workflow_run.active_ai") { EchoWorkflow.run("x") }.size
  end

  test "steps inside parallel_step still report the workflow as their caller" do
    events = capture("tool_call.active_ai") { ParallelWorkflow.run("x") }

    assert_equal 2, events.size
    assert events.all? { |e| e[:caller_type] == :workflow && e[:caller_name] == ParallelWorkflow.name }
  end

  test "a command fires command_call.active_ai" do
    events = capture("command_call.active_ai") { assert_equal "pong 1", PingCommand.new.call(argument: "1") }

    assert_equal [{ command_name: "ping", argument: "1" }], events.map { |e| e.slice(:command_name, :argument) }
  end

  test "the log subscriber writes a line for every event a component fires, without its content" do
    output = StringIO.new
    previous, ActiveSupport::LogSubscriber.logger = ActiveSupport::LogSubscriber.logger, ActiveSupport::Logger.new(output)

    ActiveSupport::Notifications.instrument("command_call.active_ai", command_name: "ping")
    ActiveSupport::Notifications.instrument("agent_usage.active_ai", agent_class: "A", model: "m", turns: 2,
                                            usage: { input_tokens: 5, output_tokens: 7 }, completed: true)
    ActiveSupport::Notifications.instrument("record_query.active_ai", root_class: "Shop", root_id: "1",
                                            association: "orders", outcome: :read, returned: 3, truncated: true)

    assert_match(/ActiveAI command.*ping/, output.string)
    assert_match(/ActiveAI usage.*turns=2 in=5 out=7/, output.string)
    assert_match(/ActiveAI query.*Shop 1 orders.*rows=3\+/, output.string)
  ensure
    ActiveSupport::LogSubscriber.logger = previous
  end

  private

  def capture(name, &)
    events     = []
    subscriber = ActiveSupport::Notifications.subscribe(name) { |*, payload| events << payload }
    yield
    events
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end
end
