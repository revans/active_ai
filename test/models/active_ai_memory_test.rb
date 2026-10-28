require "test_helper"

# Coverage for ActiveAIMemory — the memory subsystem's core AR model. Zero
# tests referenced this model before; that's how a real bug survived: the
# `summary` text column was never wired up with `serialize ... coder: JSON`
# even though the migration file's own comment promised it. Without that,
# ActiveAIMemory#summary= squashed a Hash to Ruby's inspect format
# (`{"a" => 1}`, not JSON), and Memory::Formatter's `JSON.parse` on the way
# back out raised on every real recall.
class ActiveAIMemoryTest < ActiveSupport::TestCase
  teardown { ActiveAIMemory.delete_all }

  test "summary round-trips as a Hash, not Hash#to_s" do
    memory = ActiveAIMemory.create!(agent_class: "WriterAgent", tier: "warm", summary: { "decisions" => [{ "description" => "x" }] })

    reloaded = ActiveAIMemory.find(memory.id)
    assert_equal({ "decisions" => [{ "description" => "x" }] }, reloaded.summary)
  end

  # The column holds JSON a reader outside Rails can parse, not Ruby's Hash#to_s. Booting with
  # no memory tables (or no database at all) is covered by ActiveAIBootWithoutDatabaseTest.
  test "summary is stored as JSON in the column" do
    memory = ActiveAIMemory.create!(agent_class: "WriterAgent", tier: "warm", summary: { "a" => 1 })
    raw    = ActiveAIMemory.connection.select_value("SELECT summary FROM active_ai_memories WHERE id = #{memory.id.to_i}")

    assert_equal({ "a" => 1 }, JSON.parse(raw))
  end

  test "requires agent_class" do
    memory = ActiveAIMemory.new(tier: "warm", summary: {})
    refute memory.valid?
    assert_includes memory.errors[:agent_class], "can't be blank"
  end

  test "rejects a nil summary" do
    memory = ActiveAIMemory.new(agent_class: "WriterAgent", tier: "warm", summary: nil)
    refute memory.valid?
    assert_includes memory.errors[:summary], "can't be blank"
  end

  test "accepts an empty Hash summary" do
    memory = ActiveAIMemory.new(agent_class: "WriterAgent", tier: "warm", summary: {})
    assert memory.valid?
  end

  test "rejects a tier outside warm/cold" do
    memory = ActiveAIMemory.new(agent_class: "WriterAgent", tier: "hot", summary: {})
    refute memory.valid?
    assert_includes memory.errors[:tier], "must be warm or cold"
  end

  test "warm and cold scopes filter by tier" do
    warm = ActiveAIMemory.create!(agent_class: "WriterAgent", tier: "warm", summary: {})
    cold = ActiveAIMemory.create!(agent_class: "WriterAgent", tier: "cold", summary: {})

    assert_includes ActiveAIMemory.warm, warm
    refute_includes ActiveAIMemory.warm, cold
    assert_includes ActiveAIMemory.cold, cold
    refute_includes ActiveAIMemory.cold, warm
  end

  test "destroying a memory destroys its dependent embeddings and flags" do
    memory = ActiveAIMemory.create!(agent_class: "WriterAgent", tier: "warm", summary: {})
    embedding = ActiveAIMemoryEmbedding.create!(memory_id: memory.id, vector_id: "1", vector_store: "pgvector")
    flag = ActiveAIMemoryFlag.create!(memory_id: memory.id, flag_type: "contradiction")

    memory.destroy!

    refute ActiveAIMemoryEmbedding.exists?(embedding.id)
    refute ActiveAIMemoryFlag.exists?(flag.id)
  end
end
