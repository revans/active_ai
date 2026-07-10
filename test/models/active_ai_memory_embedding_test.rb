require "test_helper"

class ActiveAIMemoryEmbeddingTest < ActiveSupport::TestCase
  teardown do
    ActiveAIMemoryEmbedding.delete_all
    ActiveAIMemory.delete_all
  end

  setup { @memory = ActiveAIMemory.create!(agent_class: "WriterAgent", tier: "warm", summary: {}) }

  test "requires vector_id" do
    embedding = ActiveAIMemoryEmbedding.new(memory_id: @memory.id, vector_store: "pgvector")
    refute embedding.valid?
    assert_includes embedding.errors[:vector_id], "can't be blank"
  end

  test "requires vector_store" do
    embedding = ActiveAIMemoryEmbedding.new(memory_id: @memory.id, vector_id: "1", vector_store: nil)
    refute embedding.valid?
    assert_includes embedding.errors[:vector_store], "can't be blank"
  end

  test "valid with memory, vector_id, and vector_store" do
    embedding = ActiveAIMemoryEmbedding.new(memory_id: @memory.id, vector_id: "1", vector_store: "pgvector")
    assert embedding.valid?
  end

  test "belongs to its memory" do
    embedding = ActiveAIMemoryEmbedding.create!(memory_id: @memory.id, vector_id: "1", vector_store: "pgvector")
    assert_equal @memory, embedding.memory
  end
end
