require "test_helper"

class ActiveAIMemoryFlagTest < ActiveSupport::TestCase
  teardown do
    ActiveAIMemoryFlag.delete_all
    ActiveAIMemory.delete_all
  end

  setup { @memory = ActiveAIMemory.create!(agent_class: "WriterAgent", tier: "warm", summary: {}) }

  test "requires flag_type" do
    flag = ActiveAIMemoryFlag.new(memory_id: @memory.id)
    refute flag.valid?
    assert_includes flag.errors[:flag_type], "can't be blank"
  end

  test "defaults status to pending" do
    flag = ActiveAIMemoryFlag.create!(memory_id: @memory.id, flag_type: "contradiction")
    assert_equal "pending", flag.status
  end

  test "belongs to its memory" do
    flag = ActiveAIMemoryFlag.create!(memory_id: @memory.id, flag_type: "superseded")
    assert_equal @memory, flag.memory
  end
end
