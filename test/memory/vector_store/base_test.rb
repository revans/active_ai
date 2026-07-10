require "test_helper"

# ActiveAI::Memory::VectorStore::Base is the abstract adapter contract — every
# method must raise until a subclass implements it, the same shape as
# Tool::Base and Command::Base's NotImplementedError contracts elsewhere in
# this gem.
class ActiveAIMemoryVectorStoreBaseTest < ActiveSupport::TestCase
  setup { @adapter = ActiveAI::Memory::VectorStore::Base.new }

  test "upsert raises NotImplementedError" do
    assert_raises(NotImplementedError) { @adapter.upsert(memory_id: 1, embedding: [0.1]) }
  end

  test "query raises NotImplementedError" do
    assert_raises(NotImplementedError) { @adapter.query(embedding: [0.1]) }
  end

  test "delete raises NotImplementedError" do
    assert_raises(NotImplementedError) { @adapter.delete(memory_id: 1) }
  end
end
