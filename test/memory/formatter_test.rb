require "test_helper"

class ActiveAIMemoryFormatterTest < ActiveSupport::TestCase
  FakeAgent = Class.new

  teardown { ActiveAIMemory.delete_all }

  test "returns empty string when the memory table does not exist" do
    ActiveAIMemory.define_singleton_method(:table_exists?) { false }
    assert_equal "", ActiveAI::Memory::Formatter.content(agent_class: FakeAgent)
  ensure
    ActiveAIMemory.singleton_class.send(:remove_method, :table_exists?)
  end

  test "returns empty string when recall finds nothing" do
    assert_equal "", ActiveAI::Memory::Formatter.content(agent_class: FakeAgent)
  end

  test "formats decisions, open threads, and observations into one block" do
    ActiveAIMemory.create!(
      agent_class: FakeAgent.name, tier: "warm",
      summary: {
        "decisions"          => [{ "description" => "use tabs" }],
        "open_threads"       => [{ "description" => "confirm scope" }],
        "agent_observations" => [{ "description" => "user prefers brevity" }]
      }
    )

    content = ActiveAI::Memory::Formatter.content(agent_class: FakeAgent, strategy: :warm)

    assert_match(/Historical context/, content)
    assert_match(/Decisions: use tabs/, content)
    assert_match(/Open threads: confirm scope/, content)
    assert_match(/Observations: user prefers brevity/, content)
  end

  test "format_memory returns empty string for an unparseable string summary, instead of raising" do
    fake_memory = Struct.new(:summary).new("not json")
    assert_equal "", ActiveAI::Memory::Formatter.format_memory(fake_memory)
  end

  test "format_memory returns empty string for a non-Hash, non-String summary" do
    fake_memory = Struct.new(:summary).new(42)
    assert_equal "", ActiveAI::Memory::Formatter.format_memory(fake_memory)
  end

  test "format_for_injection returns empty string when every formatted line is empty" do
    blank_memory = Struct.new(:summary).new({})
    assert_equal "", ActiveAI::Memory::Formatter.format_for_injection([blank_memory])
  end
end
