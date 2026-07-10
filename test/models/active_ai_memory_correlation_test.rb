require "test_helper"

# ActiveAIMemoryCorrelation enforces memory_a_id < memory_b_id at the model
# layer to prevent duplicate (A,B)/(B,A) pairs. This is a pure unhappy-path
# contract, so the tests are almost entirely about the ways it should refuse.
class ActiveAIMemoryCorrelationTest < ActiveSupport::TestCase
  teardown do
    ActiveAIMemoryCorrelation.delete_all
    ActiveAIMemory.delete_all
  end

  setup do
    @a = ActiveAIMemory.create!(agent_class: "WriterAgent", tier: "warm", summary: {})
    @b = ActiveAIMemory.create!(agent_class: "WriterAgent", tier: "warm", summary: {})
  end

  test "accepts a pair where memory_a_id < memory_b_id" do
    low, high = [@a.id, @b.id].sort
    correlation = ActiveAIMemoryCorrelation.new(memory_a_id: low, memory_b_id: high)
    assert correlation.valid?
  end

  test "rejects a pair where memory_a_id > memory_b_id" do
    low, high = [@a.id, @b.id].sort
    correlation = ActiveAIMemoryCorrelation.new(memory_a_id: high, memory_b_id: low)
    refute correlation.valid?
    assert_includes correlation.errors[:memory_a_id], "must be less than memory_b_id"
  end

  test "rejects a pair where memory_a_id equals memory_b_id" do
    correlation = ActiveAIMemoryCorrelation.new(memory_a_id: @a.id, memory_b_id: @a.id)
    refute correlation.valid?
    assert_includes correlation.errors[:memory_a_id], "must be less than memory_b_id"
  end

  test "requires both memory_a_id and memory_b_id" do
    correlation = ActiveAIMemoryCorrelation.new
    refute correlation.valid?
    assert_includes correlation.errors[:memory_a_id], "can't be blank"
    assert_includes correlation.errors[:memory_b_id], "can't be blank"
  end
end
