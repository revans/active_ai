require "test_helper"

# Adversarial cache / prompt-caching tests.
# Covers: cacheable: shape, Anthropic cache_control injection, TTL forwarding,
# unknown keys, conflicting declarations, and nil/empty system guard.
#
# Strategy: call private Anthropic provider methods directly via send() rather than
# going through the full HTTP stack. No real API calls are made.
#
# VERDICT legend:
#   PASS  — existing code handles it correctly
#   FIX   — a code change was required; the test describes the expected (fixed) behavior
#   DOC   — silent failure / intended behaviour, documented here

# ── Section 1: DSL shape (what does cacheable: contain?) ────────────────────────────
class ActiveAICacheDSLShapeTest < ActiveSupport::TestCase

  # (1) No cache DSL → cacheable is {}
  # VERDICT: PASS
  test "no cache DSL — cacheable is an empty hash in canonical params" do
    agent  = WritingAgent.new(system: "test", message: "hi")
    params = agent.to_canonical_params
    assert_equal({}, params[:cacheable],
      "cacheable must be {} when no cache DSL is called on the agent class")
  end

  # (2) Single cache :system, ttl: "1h" → { system: "1h" }
  # VERDICT: PASS
  test "cache :system, ttl: 1h — cacheable[:system] is the TTL string" do
    klass  = Class.new(WritingAgent) { cache :system, ttl: "1h" }
    agent  = klass.new(system: "test system", message: "hi")
    cacheable = agent.to_canonical_params[:cacheable]
    assert_equal "1h", cacheable[:system],
      "cacheable[:system] must be the TTL string passed to the cache DSL"
  end

  # Multiple cache declarations ─────────────────────────────────────────────────
  test "cache :source_files, ttl: 30m — cacheable[:source_files] is set" do
    klass = Class.new(WritingAgent) { cache :source_files, ttl: "30m" }
    assert_equal "30m", klass.new(system: "t", message: "m").to_canonical_params[:cacheable][:source_files]
  end

  test "cache :context, ttl: 5m — cacheable[:context] is set" do
    klass = Class.new(WritingAgent) { cache :context, ttl: "5m" }
    assert_equal "5m", klass.new(system: "t", message: "m").to_canonical_params[:cacheable][:context]
  end

  test "multiple cache declarations accumulate independently" do
    klass = Class.new(WritingAgent) do
      cache :system,       ttl: "1h"
      cache :source_files, ttl: "30m"
      cache :context,      ttl: "5m"
    end
    cacheable = klass.new(system: "t", message: "m").to_canonical_params[:cacheable]
    assert_equal "1h",  cacheable[:system]
    assert_equal "30m", cacheable[:source_files]
    assert_equal "5m",  cacheable[:context]
  end

  # (3) Conflicting declarations — last wins
  # VERDICT: PASS — _cache_config uses merge(), so the last call overwrites earlier ones
  test "two cache :system declarations — last TTL wins" do
    klass = Class.new(WritingAgent) do
      cache :system, ttl: "1h"
      cache :system, ttl: "5m"
    end
    cacheable = klass.new(system: "test", message: "hi").to_canonical_params[:cacheable]
    assert_equal "5m", cacheable[:system],
      "last cache :system declaration must overwrite the earlier one via merge"
  end

  test "last cache :context wins when declared twice" do
    klass = Class.new(WritingAgent) do
      cache :context, ttl: "1h"
      cache :context, ttl: "10m"
    end
    cacheable = klass.new(system: "t", message: "m").to_canonical_params[:cacheable]
    assert_equal "10m", cacheable[:context]
  end

  # (4) cache :messages — stored and NOW consumed: injects cache_control on the
  # last user message in the messages array (the conversation history boundary).
  # VERDICT: FIX — previously DOC'd as a silent no-op. Now implemented.
  # The Anthropic provider still does NOT touch system blocks for :messages.
  test "cache :messages — stored in cacheable and injects on last user message" do
    klass     = Class.new(WritingAgent) { cache :messages, ttl: "5m" }
    agent     = klass.new(system: "test", message: "hi")
    cacheable = agent.to_canonical_params[:cacheable]

    # Key IS stored in _cache_config
    assert_equal "5m", cacheable[:messages],
      "cache :messages must be stored in cacheable"

    # Must NOT inject into system blocks — only :system and :source_files do that
    provider  = ActiveAI::Provider::Anthropic.new
    canonical = agent.to_canonical_params
    blocks    = provider.send(:build_system_blocks, canonical)
    assert blocks.none? { |b| b.key?(:cache_control) },
      "cache :messages must NOT inject cache_control into system blocks"

    # MUST expand the last user message to a block array with cache_control
    messages = provider.send(:build_messages_with_cache, canonical)
    assert_kind_of Array, messages.last[:content],
      "cache :messages MUST expand the last user message content to a block Array"
    assert_equal({ type: "ephemeral" }, messages.last[:content].last[:cache_control],
      "cache :messages must inject { type: ephemeral } cache_control on the last user message")
  end
end

# ── Section 2: Anthropic provider cache_control injection ────────────────────────────
class AnthropicCacheInjectionTest < ActiveSupport::TestCase
  # Builds a minimal canonical hash so we can call private provider methods directly.
  def canonical(cacheable: {}, system: "you are helpful",
                messages: [{ role: "user", content: "hello" }],
                source_files: [])
    {
      model:        "claude-sonnet-4-6",
      max_tokens:   1024,
      system:       system,
      skills:       [],
      source_files: source_files,
      messages:     messages,
      cacheable:    cacheable
    }
  end

  # (5) cache_control must NOT include :ttl — Anthropic rejects unknown fields
  # VERDICT: FIX — build_system_blocks was doing:
  #   { type: "ephemeral", ttl: cacheable[:system] }
  # Anthropic's API only supports { type: "ephemeral" }. Sending a :ttl key
  # produces a 422 in production. The TTL is active_ai metadata, not an API field.
  # Fix: strip :ttl from all three cache_control hashes in the Anthropic provider.
  test "cache :system — cache_control is { type: ephemeral } with no :ttl key" do
    provider = ActiveAI::Provider::Anthropic.new
    c        = canonical(cacheable: { system: "1h" })
    blocks   = provider.send(:build_system_blocks, c)

    system_block = blocks.first
    refute_nil system_block[:cache_control],
      "cache :system must inject cache_control onto the system block"
    assert_equal({ type: "ephemeral" }, system_block[:cache_control],
      "cache_control must be exactly { type: 'ephemeral' } — Anthropic rejects :ttl and any other extra keys")
  end

  test "cache :source_files — cache_control is { type: ephemeral } with no :ttl key" do
    provider  = ActiveAI::Provider::Anthropic.new
    fake_file = Struct.new(:name, :content).new("essay.txt", "Once upon a time...")
    c         = canonical(cacheable: { source_files: "1h" }, source_files: [fake_file])
    blocks    = provider.send(:build_system_blocks, c)

    sf_block = blocks.last  # source_files block is appended after system block
    refute_nil sf_block[:cache_control],
      "cache :source_files must inject cache_control onto the source files block"
    assert_equal({ type: "ephemeral" }, sf_block[:cache_control],
      "source_files cache_control must not include :ttl")
  end

  test "cache :context — cache_control on first message is { type: ephemeral } with no :ttl key" do
    provider = ActiveAI::Provider::Anthropic.new
    c        = canonical(
      cacheable: { context: "5m" },
      messages:  [{ role: "user", content: "the document body" }]
    )
    messages = provider.send(:build_messages_with_cache, c)

    first_content = messages.first[:content]
    assert_kind_of Array, first_content,
      "cache :context must expand first message content to an Array of content blocks"
    block = first_content.first
    refute_nil block[:cache_control],
      "cache :context must inject cache_control onto the first message content block"
    assert_equal({ type: "ephemeral" }, block[:cache_control],
      "context cache_control must not include :ttl")
  end

  # (5b) TTL values of any length must NOT be forwarded
  test "cache :system with 30m TTL — still no :ttl in cache_control" do
    provider = ActiveAI::Provider::Anthropic.new
    c        = canonical(cacheable: { system: "30m" })
    blocks   = provider.send(:build_system_blocks, c)
    assert_equal({ type: "ephemeral" }, blocks.first[:cache_control])
  end

  # No cacheable → no cache_control
  test "no cacheable for :system — cache_control is absent from system block" do
    provider = ActiveAI::Provider::Anthropic.new
    c        = canonical(cacheable: {})
    blocks   = provider.send(:build_system_blocks, c)
    refute blocks.first&.key?(:cache_control),
      "when cacheable[:system] is absent, the system block must have no cache_control"
  end

  test "no cacheable for :context — first message content stays a String" do
    provider = ActiveAI::Provider::Anthropic.new
    c        = canonical(cacheable: {}, messages: [{ role: "user", content: "hello" }])
    messages = provider.send(:build_messages_with_cache, c)
    assert_kind_of String, messages.first[:content],
      "without cache :context, first message content must remain a plain String"
  end

  test "no cacheable for :source_files — source files block has no cache_control" do
    provider  = ActiveAI::Provider::Anthropic.new
    fake_file = Struct.new(:name, :content).new("notes.txt", "content")
    c         = canonical(cacheable: {}, source_files: [fake_file])
    blocks    = provider.send(:build_system_blocks, c)
    sf_block  = blocks.last
    refute sf_block.key?(:cache_control),
      "without cache :source_files, the source files block must have no cache_control"
  end

  # (6) cache :system with nil/empty system prompt — must not crash
  # VERDICT: PASS — build_system_blocks guards with blank? before building any blocks
  test "cache :system with nil system — no crash, no system block produced" do
    provider = ActiveAI::Provider::Anthropic.new
    c        = canonical(cacheable: { system: "1h" }, system: nil)
    blocks   = nil
    # cache :system with nil system must not raise — blank? guard protects it
    assert_nothing_raised { blocks = provider.send(:build_system_blocks, c) }
    assert_empty blocks,
      "nil system must produce zero blocks even when cache :system is declared"
  end

  test "cache :system with empty string system — no crash, no block" do
    provider = ActiveAI::Provider::Anthropic.new
    c        = canonical(cacheable: { system: "1h" }, system: "")
    blocks   = nil
    assert_nothing_raised { blocks = provider.send(:build_system_blocks, c) }
    assert_empty blocks
  end

  test "cache :system with whitespace-only system — no crash, no block" do
    provider = ActiveAI::Provider::Anthropic.new
    c        = canonical(cacheable: { system: "1h" }, system: "   \n  ")
    blocks   = nil
    assert_nothing_raised { blocks = provider.send(:build_system_blocks, c) }
    assert_empty blocks
  end

  # cache :context with empty messages — must not crash
  test "cache :context with empty messages array — no crash, no expansion" do
    provider = ActiveAI::Provider::Anthropic.new
    c        = canonical(cacheable: { context: "5m" }, messages: [])
    assert_nothing_raised { provider.send(:build_messages_with_cache, c) }
  end

  # cache :context does NOT inject when first message is assistant role
  test "cache :context when first message is assistant role — no expansion" do
    provider = ActiveAI::Provider::Anthropic.new
    c        = canonical(
      cacheable: { context: "5m" },
      messages:  [{ role: "assistant", content: "I am ready." }]
    )
    messages = provider.send(:build_messages_with_cache, c)
    assert_kind_of String, messages.first[:content],
      "cache :context must NOT expand non-user first messages"
  end

  # cache :context preserves original text in the expanded block
  test "cache :context preserves the original message text in the expanded block" do
    provider  = ActiveAI::Provider::Anthropic.new
    doc_text  = "This is the document body with lots of content."
    c         = canonical(
      cacheable: { context: "5m" },
      messages:  [{ role: "user", content: doc_text }]
    )
    messages = provider.send(:build_messages_with_cache, c)
    text_block = messages.first[:content].first
    assert_equal "text",    text_block[:type]
    assert_equal doc_text,  text_block[:text],
      "cache :context must preserve original message text in the expanded block"
  end

  # Both system and context cacheable — both inject independently
  test "cache :system and :context together — both inject cache_control" do
    provider = ActiveAI::Provider::Anthropic.new
    c        = canonical(
      cacheable: { system: "1h", context: "5m" },
      system:    "system prompt",
      messages:  [{ role: "user", content: "doc body" }]
    )
    blocks   = provider.send(:build_system_blocks, c)
    messages = provider.send(:build_messages_with_cache, c)

    assert blocks.first[:cache_control].present?,
      "system block must have cache_control when cache :system is active"
    assert_kind_of Array, messages.first[:content],
      "first message must be expanded when cache :context is active"
  end
end
