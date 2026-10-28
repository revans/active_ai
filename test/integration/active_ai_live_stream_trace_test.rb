require "test_helper"

# ActionController::Live runs the action on a thread of its own. The run started there must still carry the Rails
# request id, and an app saving the message in after_stream must be able to file it under the same run.
class ActiveAILiveStreamTraceTest < ActiveSupport::TestCase
  class StreamingController < ActionController::Base
    include ActiveAI::Concerns::Streamable

    cattr_accessor :agent, :saved

    def show
      stream_agent(agent) do |text|
        self.class.saved = { text: text, run: ActiveAI::Instrumentation.current_run, run_id: agent.run_id }
      end
    end
  end

  def openai_agent
    chunks = [
      { "id" => "chatcmpl-9", "choices" => [ { "delta" => { "content" => "Friday." }, "finish_reason" => nil } ], "usage" => nil },
      { "id" => "chatcmpl-9", "choices" => [ { "delta" => {}, "finish_reason" => "stop" } ], "usage" => nil },
      { "id" => "chatcmpl-9", "choices" => [], "usage" => { "prompt_tokens" => 3, "completion_tokens" => 2 } }
    ]
    provider = ActiveAI::Provider::OpenAI.new
    fake = Object.new
    fake.define_singleton_method(:chat) { |parameters:| chunks.each { |chunk| parameters[:stream].call(chunk, nil) } }
    provider.instance_variable_set(:@client, fake)
    agent = WritingAgent.new(system: "s", message: "when do we ship?")
    agent.define_singleton_method(:provider_instance) { provider }
    agent
  end

  test "a streamed run carries the request id, and after_stream runs inside the same run" do
    StreamingController.agent = openai_agent
    events     = []
    subscriber = ActiveSupport::Notifications.subscribe(/\.active_ai\z/) { |name, *, payload| events << [name, payload] }

    env = Rack::MockRequest.env_for("/stream").merge("action_dispatch.request_id" => "req-live-1")
    status, _headers, body = StreamingController.action(:show).call(env)
    streamed = +""
    body.each { |part| streamed << part }
    body.close if body.respond_to?(:close)

    assert_equal 200, status
    assert_includes streamed, "Friday."

    run_ids = events.map { |_, payload| payload[:run_id] }.uniq
    assert_equal 1, run_ids.size, "every event of the stream belongs to one run: #{events.map(&:first)}"
    assert events.all? { |_, payload| payload[:request_id] == "req-live-1" }, "every event carries the request id"
    assert events.any? { |name, _| name == "agent_request.active_ai" }

    saved = StreamingController.saved
    assert_equal "Friday.", saved[:text]
    assert_equal run_ids.first, saved[:run_id]
    assert_equal run_ids.first, saved.dig(:run, :run_id), "after_stream runs inside the stream's run"
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end
end
