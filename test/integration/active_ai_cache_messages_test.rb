require "test_helper"

# Adversarial integration tests for cache :messages — the "last user message"
# cache injection on the Anthropic provider.
#
# Mental model: think of Anthropic's cache_control as a bookmark you stick into
# the conversation. Anything BEFORE the bookmark is cached and reused on the next
# request. cache :context puts the bookmark after the first user message (the
# document body — stable, never changes). cache :messages puts the bookmark after
# the last user message (the current end of the conversation thread — caches all
# history so far). Anthropic supports up to 4 bookmarks per request.
#
# Strategy: call private Anthropic provider methods directly via send() — no
# real API calls, no HTTP.
#
# VERDICT legend:
#   PASS  — existing code handles it correctly
#   FIX   — a code change was required

class CacheMessagesTest < ActiveSupport::TestCase

  def canonical(cacheable: {}, messages: [{ role: "user", content: "hello" }])
    {
      model:        "claude-sonnet-4-6",
      max_tokens:   1024,
      system:       "test system",
      skills:       [],
      source_files: [],
      messages:     messages,
      cacheable:    cacheable
    }
  end

  # ── 1. DSL stores the key ─────────────────────────────────────────────────────
  # VERDICT: PASS — the key IS stored in cacheable via Base#cache; the gap was that
  # the Anthropic provider ignored it in build_messages_with_cache.

  test "cache :messages — stored in cacheable as the TTL string" do
    klass     = Class.new(WritingAgent) { cache :messages, ttl: "5m" }
    cacheable = klass.new(system: "t", message: "m").to_canonical_params[:cacheable]
    assert_equal "5m", cacheable[:messages],
      "cache :messages must store the TTL string in cacheable — it is not a no-op key"
  end

  # ── 2. Provider injects cache_control on the last user message ────────────────
  # VERDICT: FIX — build_messages_with_cache only handled cacheable[:context].
  # Fix: when cacheable[:messages] is set, find the last user message and expand
  # its content to an array block with cache_control: { type: "ephemeral" }.

  test "cache :messages injects cache_control on the last user message" do
    provider = ActiveAI::Provider::Anthropic.new
    c = canonical(
      cacheable: { messages: "5m" },
      messages:  [{ role: "user", content: "the last message" }]
    )
    messages = provider.send(:build_messages_with_cache, c)

    last_content = messages.last[:content]
    assert_kind_of Array, last_content,
      "cache :messages must expand last user message content to a block Array"
    assert_equal({ type: "ephemeral" }, last_content.last[:cache_control],
      "cache :messages must inject { type: ephemeral } cache_control on the last content block")
  end

  test "cache :messages targets the LAST user message, not the first one" do
    provider = ActiveAI::Provider::Anthropic.new
    c = canonical(
      cacheable: { messages: "5m" },
      messages:  [
        { role: "user",      content: "first user message" },
        { role: "assistant", content: "first assistant reply" },
        { role: "user",      content: "second user message" }
      ]
    )
    messages = provider.send(:build_messages_with_cache, c)

    # First user message must NOT be expanded
    assert_kind_of String, messages[0][:content],
      "cache :messages must NOT expand non-final user messages — only the last"

    # Last user message MUST be expanded with cache_control
    assert_kind_of Array, messages[2][:content],
      "cache :messages must expand the last user message content to block Array"
    assert_equal({ type: "ephemeral" }, messages[2][:content].last[:cache_control])
  end

  test "cache :messages cache_control is exactly { type: ephemeral } — no :ttl key" do
    provider = ActiveAI::Provider::Anthropic.new
    c = canonical(cacheable: { messages: "1h" })
    messages = provider.send(:build_messages_with_cache, c)

    block = messages.last[:content].last
    assert_equal({ type: "ephemeral" }, block[:cache_control],
      "cache_control must be exactly { type: 'ephemeral' } — Anthropic rejects :ttl and extra keys")
  end

  test "cache :messages preserves original text in the expanded content block" do
    provider = ActiveAI::Provider::Anthropic.new
    c = canonical(
      cacheable: { messages: "5m" },
      messages:  [{ role: "user", content: "please write a blog post about Ruby" }]
    )
    messages = provider.send(:build_messages_with_cache, c)

    block = messages.last[:content].first
    assert_equal "text", block[:type],
      "expanded block must have type: 'text'"
    assert_equal "please write a blog post about Ruby", block[:text],
      "cache :messages must preserve the original message text"
  end

  # ── 3. Edge: assistant messages are skipped ───────────────────────────────────
  # VERDICT: FIX (with the same fix) — rindex returns nil when no user message exists

  test "cache :messages skips assistant-only messages — no injection, no crash" do
    provider = ActiveAI::Provider::Anthropic.new
    c = canonical(
      cacheable: { messages: "5m" },
      messages:  [{ role: "assistant", content: "I am ready." }]
    )
    messages = nil
    assert_nothing_raised { messages = provider.send(:build_messages_with_cache, c) }
    assert_kind_of String, messages.first[:content],
      "assistant content must remain a String — cache :messages must not inject on assistant roles"
  end

  # ── 4. Edge: empty messages — no crash ───────────────────────────────────────
  # VERDICT: FIX (with the same fix)

  test "cache :messages with empty messages array — no crash, returns empty array" do
    provider = ActiveAI::Provider::Anthropic.new
    c = canonical(cacheable: { messages: "5m" }, messages: [])
    result = nil
    assert_nothing_raised { result = provider.send(:build_messages_with_cache, c) }
    assert_empty result
  end

  # ── 5. cache :context + cache :messages on DIFFERENT messages ─────────────────
  # This is the multi-point caching case: two cache breakpoints in one request.
  # Anthropic supports up to 4 breakpoints — this exercises the two most common.
  # VERDICT: FIX — both injections happen independently in two separate passes.

  test "cache :context and cache :messages on different messages — both inject independently" do
    provider = ActiveAI::Provider::Anthropic.new
    c = canonical(
      cacheable: { context: "5m", messages: "5m" },
      messages:  [
        { role: "user",      content: "document body" },
        { role: "assistant", content: "understood" },
        { role: "user",      content: "now write a draft" }
      ]
    )
    messages = provider.send(:build_messages_with_cache, c)

    # First message: expanded by cache :context
    first_content = messages[0][:content]
    assert_kind_of Array, first_content,
      "cache :context must expand first user message to block Array"
    assert_equal({ type: "ephemeral" }, first_content.last[:cache_control],
      "cache :context must inject cache_control on first user message")

    # Third message: expanded by cache :messages
    last_content = messages[2][:content]
    assert_kind_of Array, last_content,
      "cache :messages must expand last user message to block Array"
    assert_equal({ type: "ephemeral" }, last_content.last[:cache_control],
      "cache :messages must inject cache_control on last user message")

    # Middle assistant message is untouched
    assert_kind_of String, messages[1][:content],
      "assistant message must remain a plain String — no cache injection on it"
  end

  # ── 6. cache :context + cache :messages on the SAME message (single-turn) ─────
  # When there's only one user message, both keys target it. cache :context runs
  # first and expands content to an Array with cache_control. When cache :messages
  # runs, it sees the Array and the last block already has cache_control — it must
  # NOT add a second cache_control, because duplicate breakpoints on the same block
  # are semantically redundant and the cache_control key value would just be overwritten.
  # VERDICT: FIX — guard against double injection

  test "cache :context and cache :messages same single message — cache_control appears exactly once" do
    provider = ActiveAI::Provider::Anthropic.new
    c = canonical(
      cacheable: { context: "5m", messages: "5m" },
      messages:  [{ role: "user", content: "the only message" }]
    )
    messages = provider.send(:build_messages_with_cache, c)

    content = messages.first[:content]
    assert_kind_of Array, content,
      "the single message must be expanded to block Array"
    blocks_with_cache = content.select { |b| b.key?(:cache_control) }
    assert_equal 1, blocks_with_cache.size,
      "when cache :context and cache :messages target the same message, " \
      "exactly one cache_control must appear — not two duplicated blocks"
  end

  # ── 7. cache :messages alone — no interference with :context behaviour ────────

  test "cache :messages alone does not expand first user message if it is not the last" do
    provider = ActiveAI::Provider::Anthropic.new
    c = canonical(
      cacheable: { messages: "5m" },
      messages:  [
        { role: "user",      content: "first" },
        { role: "assistant", content: "mid" },
        { role: "user",      content: "last" }
      ]
    )
    messages = provider.send(:build_messages_with_cache, c)
    assert_kind_of String, messages[0][:content],
      "without cache :context, the first user message must stay a plain String"
  end

  # ── 8. Without cache :messages — no injection ─────────────────────────────────
  # VERDICT: PASS (guard: cacheable[:messages] is falsy, the branch is never entered)

  test "no cache :messages — last user message content stays a plain String" do
    provider = ActiveAI::Provider::Anthropic.new
    c = canonical(cacheable: {})
    messages = provider.send(:build_messages_with_cache, c)
    assert_kind_of String, messages.last[:content],
      "without cache :messages declared, last user message must remain a plain String"
  end
end
