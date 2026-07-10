require "test_helper"

# ActiveAI::Memory::Store (the ActiveAI::Memory module itself) is the core
# business logic of the memory subsystem — recall strategy dispatch,
# specificity scoring, token-budget enforcement, and the access-tracking side
# effect. None of it had a single test before. Cold/hybrid recall need a real
# vector store adapter; ActiveAI.vector_store_adapter defaults to "pgvector",
# which on this sqlite test DB always returns [] (see
# memory/vector_store/pgvector_test.rb) — so cold results are exercised as
# "adapter returns nothing," not via a real similarity search.
class ActiveAIMemoryStoreTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  FakeAgent = Class.new

  teardown { ActiveAIMemory.delete_all }

  def create_memory(**attrs)
    ActiveAIMemory.create!({ agent_class: FakeAgent.name, tier: "warm", summary: {} }.merge(attrs))
  end

  # ── recall strategy dispatch ────────────────────────────────────────────────

  test "recall raises ArgumentError for an unknown strategy" do
    error = assert_raises(ArgumentError) { ActiveAI::Memory.recall(strategy: :quantum) }
    assert_match(/Unknown recall strategy/, error.message)
  end

  test "recall with :warm returns only warm memories, ranked by specificity" do
    create_memory(scope: "other")
    matching = create_memory(scope: "intro")

    results = ActiveAI::Memory.recall(agent: FakeAgent, scope: "intro", strategy: :warm)

    assert_equal [matching], results
  end

  test "recall with :cold returns empty when there is no warm anchor to seed a vector search" do
    create_memory(tier: "cold")
    assert_equal [], ActiveAI::Memory.recall(agent: FakeAgent, strategy: :cold)
  end

  test "recall with :hybrid falls back to warm-only results when cold search yields nothing" do
    warm = create_memory(scope: "intro")
    results = ActiveAI::Memory.recall(agent: FakeAgent, scope: "intro", strategy: :hybrid)
    assert_equal [warm], results
  end

  test "recall defaults to :warm when no strategy is given" do
    warm = create_memory
    assert_equal [warm], ActiveAI::Memory.recall(agent: FakeAgent)
  end

  # ── specificity scoring / ranking ───────────────────────────────────────────

  test "passing subject: filters warm recall down to only that subject's memories" do
    create_memory(scope: "intro") # no subject — must be excluded once subject: is a query dimension
    matching = create_memory(scope: "intro", subject_type: "Document", subject_id: 1)

    document = Object.new
    document.define_singleton_method(:class) { Struct.new(:name).new("Document") }
    document.define_singleton_method(:id) { 1 }

    results = ActiveAI::Memory.recall(agent: FakeAgent, subject: document, scope: "intro", strategy: :warm)

    assert_equal [matching], results
  end

  test "a nil dimension is a wildcard — does not filter results" do
    create_memory(scope: "a")
    create_memory(scope: "b")

    results = ActiveAI::Memory.recall(agent: FakeAgent, strategy: :warm)

    assert_equal 2, results.size
  end

  # ── budget enforcement ──────────────────────────────────────────────────────

  test "always includes the single highest-ranked memory even if it exceeds the budget" do
    huge_summary = { "decisions" => Array.new(500) { { "description" => "x" * 50 } } }
    oversized = create_memory(scope: "intro", summary: huge_summary)

    results = ActiveAI::Memory.recall(agent: FakeAgent, scope: "intro", strategy: :warm, token_budget: 1)

    assert_equal [oversized], results
  end

  test "excludes a later memory that would push the total over budget" do
    first  = create_memory(scope: "intro")
    second = create_memory(scope: "intro")
    # Force a stable order: first has an explicit smaller token_estimate so it
    # sorts as equally-specific-but-more-recently-accessed; both match scope
    # equally, so ranking falls back to last_accessed_at desc. Give `second`
    # a huge token_estimate so it alone blows the budget once `first` is in.
    second.update!(token_estimate: 10_000)

    results = ActiveAI::Memory.recall(agent: FakeAgent, scope: "intro", strategy: :warm, token_budget: 50)

    assert_includes results, second, "the first (highest-ranked) memory is always included"
    refute_includes results, first
  end

  # ── persist ─────────────────────────────────────────────────────────────────

  test "persist creates a new memory and estimates its token count" do
    memory = ActiveAI::Memory.persist(agent: FakeAgent, summary: { "decisions" => [] }, async: false)

    assert memory.persisted?
    assert_equal FakeAgent.name, memory.agent_class
    assert memory.token_estimate.positive?
  end

  test "persist upserts on repeated calls with the same lookup key instead of creating duplicates" do
    ActiveAI::Memory.persist(agent: FakeAgent, scope: "intro", summary: { "decisions" => [] }, async: false)
    ActiveAI::Memory.persist(agent: FakeAgent, scope: "intro", summary: { "decisions" => ["updated"] }, async: false)

    matches = ActiveAIMemory.where(agent_class: FakeAgent.name, scope: "intro")
    assert_equal 1, matches.count
    assert_equal ["updated"], matches.first.summary["decisions"]
  end

  test "persist enqueues the embed job by default" do
    memory = ActiveAI::Memory.persist(agent: FakeAgent, summary: {})
    assert_enqueued_with(job: ActiveAIMemoryEmbedJob, args: [memory.id])
  end

  test "persist with async: false does not enqueue the embed job" do
    assert_no_enqueued_jobs do
      ActiveAI::Memory.persist(agent: FakeAgent, summary: {}, async: false)
    end
  end

  # ── side effects ────────────────────────────────────────────────────────────

  test "recall increments access_count and sets last_accessed_at on returned memories" do
    memory = create_memory(access_count: 0, last_accessed_at: nil)

    ActiveAI::Memory.recall(agent: FakeAgent, strategy: :warm)

    memory.reload
    assert_equal 1, memory.access_count
    assert memory.last_accessed_at.present?
  end

  test "recall does not touch access_count when nothing matches" do
    create_memory(scope: "other")

    ActiveAI::Memory.recall(agent: FakeAgent, scope: "no-match", strategy: :warm)

    assert_equal 0, ActiveAIMemory.sum(:access_count)
  end
end
