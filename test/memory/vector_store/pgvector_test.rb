require "test_helper"

# ActiveAI::Memory::VectorStore::Pgvector, exercised against the dummy app's
# real sqlite test database. Every public method has a `sqlite?` guard clause
# — that's not a stub for these tests, it's the actual code path this adapter
# takes in any host app running Solid Stack (sqlite) alongside a Postgres
# primary DB, per the adapter's own class comment. The postgres-only
# `nearest_neighbors` path (behind the guard) needs a real pgvector-backed
# Postgres connection and is out of reach of this sqlite-only test suite —
# noted here rather than silently skipped.
class ActiveAIMemoryVectorStorePgvectorTest < ActiveSupport::TestCase
  setup { @adapter = ActiveAI::Memory::VectorStore::Pgvector.new }
  teardown { ActiveAIMemoryEmbedding.delete_all }

  test "name is pgvector" do
    assert_equal "pgvector", @adapter.name
  end

  test "upsert on sqlite returns a stub id without writing a row" do
    result = @adapter.upsert(memory_id: 1, embedding: [0.1, 0.2, 0.3])

    assert_equal "stub-1", result
    assert_equal 0, ActiveAIMemoryEmbedding.count
  end

  test "query on sqlite returns an empty array" do
    assert_equal [], @adapter.query(embedding: [0.1, 0.2, 0.3])
  end

  test "query on sqlite returns empty even with a filter" do
    assert_equal [], @adapter.query(embedding: [0.1], limit: 5, filter: { tier: "cold" })
  end

  test "delete on sqlite is a no-op and does not raise" do
    assert_nil @adapter.delete(memory_id: 1)
  end
end
