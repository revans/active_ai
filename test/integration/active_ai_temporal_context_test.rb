require "test_helper"

# Unit coverage for ActiveAI::Concerns::TemporalContext.
#
# This concern depends on a hook convention the gem itself does not define
# or call anywhere — ApplicationAgent#build_messages (see
# test/dummy/app/ai/agents/application_agent.rb) inlines its own
# history/message logic directly, with no history_message_content(msg) /
# current_message_content calls at all. That convention exists only because
# a *consuming app's own* ApplicationAgent happens to define and call those
# two methods from its own build_messages. So this test builds a small
# two-level class structure that mirrors that real shape — a base class that
# defines and calls the hooks (standing in for an app's own ApplicationAgent)
# and a leaf class that only adds the concern (standing in for WritingAgent)
# — to prove what this concern actually promises: "if your build_messages
# calls these two hooks, this concern stamps them." It does not prove every
# ActiveAI::Agent::Base subclass gets this for free, because it doesn't.
class ActiveAITemporalContextTest < ActiveSupport::TestCase
  FakeMessage = Struct.new(:role, :content, :attached_file_name, :attached_file_content, :created_at, keyword_init: true)

  HookedBase = Class.new(ApplicationAgent) do
    private

    def history_message_content(msg)
      content = msg.content.to_s
      return content unless msg.attached_file_content.present?
      "Attached file — #{msg.attached_file_name}:\n#{msg.attached_file_content}\n\n#{content}"
    end

    def current_message_content
      @message
    end

    def build_messages
      messages = @history.map { |msg| { role: msg.role.to_s, content: history_message_content(msg) } }
      messages << { role: "user", content: current_message_content } if @message.present?
      messages
    end
  end

  StampedAgent = Class.new(HookedBase) do
    include ActiveAI::Concerns::TemporalContext
  end

  test "stamps each history message with when it was actually sent" do
    sent_at = Time.zone.parse("2026-07-08 2:47 PM")
    history = [ FakeMessage.new(role: "user", content: "hi", created_at: sent_at) ]
    agent   = StampedAgent.new(system: "s", history: history)

    content = agent.send(:build_messages).first[:content]
    assert_includes content, "2026-07-08 2:47 PM"
    assert_includes content, "hi"
  end

  test "stamps the current message with the current time" do
    travel_to Time.zone.parse("2026-07-08 15:00") do
      agent   = StampedAgent.new(system: "s", message: "what time is it")
      content = agent.send(:build_messages).last[:content]
      assert_includes content, "2026-07-08 3:00 PM"
      assert_includes content, "what time is it"
    end
  end

  test "stamp comes before the message content" do
    travel_to Time.zone.parse("2026-07-08 15:00") do
      agent   = StampedAgent.new(system: "s", message: "hello")
      content = agent.send(:build_messages).last[:content]
      assert content.index("2026-07-08") < content.index("hello")
    end
  end

  test "preserves attached-file prefixing on history messages" do
    sent_at = Time.zone.parse("2026-07-08 2:47 PM")
    history = [
      FakeMessage.new(
        role: "user", content: "check this",
        attached_file_name: "notes.txt", attached_file_content: "note contents",
        created_at: sent_at
      )
    ]
    agent = StampedAgent.new(system: "s", history: history)

    content = agent.send(:build_messages).first[:content]
    assert_includes content, "Attached file — notes.txt"
    assert_includes content, "note contents"
    assert_includes content, "2026-07-08 2:47 PM"
  end

  test "does not stamp assistant history messages, so the model never sees itself doing it" do
    history = [
      FakeMessage.new(role: "assistant", content: "Sure, here's a draft.", created_at: Time.zone.parse("2026-07-08 2:47 PM"))
    ]
    agent = StampedAgent.new(system: "s", history: history)

    assert_equal "Sure, here's a draft.", agent.send(:build_messages).first[:content]
  end

  test "an agent without the concern is unaffected" do
    sent_at = Time.zone.parse("2026-07-08 2:47 PM")
    history  = [ FakeMessage.new(role: "user", content: "hi", created_at: sent_at) ]
    unstamped_agent = HookedBase.new(system: "s", history: history)

    assert_equal "hi", unstamped_agent.send(:build_messages).first[:content]
  end
end
