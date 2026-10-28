require "test_helper"

# A client that goes away mid-answer must not leave the app thinking the answer finished:
# after_stream is told whether the stream completed, so a cut-off answer can be saved as
# failed instead of complete (Atlas F-066 fresh-eyes review).
class ActiveAIStreamDisconnectTest < ActiveSupport::TestCase
  class StreamingController < ActionController::Base
    include ActiveAI::Concerns::Streamable

    cattr_accessor :agent, :seen, :style

    def show
      if style == :keyword
        stream_agent(agent) { |text, completed:| self.class.seen = { text: text, completed: completed } }
      else
        stream_agent(agent) { |text| self.class.seen = { text: text } }
      end
    end
  end

  # Streams its chunks, then (optionally) loses the client, as a closed tab does mid-write.
  def agent_streaming(*chunks, disconnect:)
    agent = Object.new
    agent.define_singleton_method(:stream) do |&block|
      chunks.each { |chunk| block.call(chunk) }
      raise ActionController::Live::ClientDisconnected, "client disconnected" if disconnect
    end
    agent
  end

  def stream(agent, style)
    StreamingController.agent = agent
    StreamingController.style = style
    StreamingController.seen  = nil
    _status, _headers, body = StreamingController.action(:show).call(Rack::MockRequest.env_for("/stream"))
    body.each { |_| }
    body.close if body.respond_to?(:close)
    StreamingController.seen
  end

  test "a disconnect mid-answer reaches after_stream as completed: false, with what was said" do
    assert_equal({ text: "Partial ", completed: false }, stream(agent_streaming("Partial ", disconnect: true), :keyword))
  end

  test "a disconnect before the first word is completed: false with empty text" do
    assert_equal({ text: "", completed: false }, stream(agent_streaming(disconnect: true), :keyword))
  end

  test "an answer that finishes is completed: true" do
    assert_equal({ text: "Done.", completed: true }, stream(agent_streaming("Done.", disconnect: false), :keyword))
  end

  test "a block that takes only the text still gets it" do
    assert_equal({ text: "Partial " }, stream(agent_streaming("Partial ", disconnect: true), :text_only))
  end
end
