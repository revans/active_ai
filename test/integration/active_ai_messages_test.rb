require "test_helper"

# Adversarial message-building tests — probing build_messages, build_system_blocks,
# and related layers for silent bad data, missing guards, and ordering invariants.
# No real LLM calls — everything exercised at the param-construction layer.
#
# Verdict legend (added after first run):
#   PASS — existing code handles it correctly
#   FIX  — code was changed to produce the correct guard or typed error
#   DOC  — silent/intended behavior; documented here, no fix expected
class ActiveAIMessagesTest < ActiveSupport::TestCase

  # Duck-typed history message — mirrors the interface consumed by build_messages.
  # role, content, attached_file_content, attached_file_name are all the fields accessed.
  HistoryMsg = Struct.new(:role, :content, :attached_file_content, :attached_file_name, keyword_init: true)

  # ── Test 1: Alternating roles invariant ──────────────────────────────────────
  # Anthropic requires strictly alternating user/assistant messages.
  # If history contains two consecutive user messages (a bug in the caller),
  # build_messages must detect it and raise rather than silently handing a
  # role-sequence violation to the API, which returns a 400.
  #
  # VERDICT: FIX — build_messages now raises ArgumentError on consecutive same-role messages.

  test "consecutive user messages in history raise ArgumentError — silent pass-through causes Anthropic 400" do
    history = [
      HistoryMsg.new(role: "user",      content: "first question"),
      HistoryMsg.new(role: "user",      content: "follow-up question"), # same role — invalid
      HistoryMsg.new(role: "assistant", content: "response")
    ]
    agent = WritingAgent.new(system: "test", history: history, message: "current")

    error = assert_raises(ArgumentError,
      "consecutive user→user messages must raise ArgumentError; silent pass-through causes Anthropic 400") do
      agent.complete
    end
    assert_match(/role|alternating|consecutive/i, error.message,
      "error message must name the problem — got: #{error.message.inspect}")
  end

  test "consecutive assistant messages in history raise ArgumentError" do
    history = [
      HistoryMsg.new(role: "user",      content: "question"),
      HistoryMsg.new(role: "assistant", content: "first answer"),
      HistoryMsg.new(role: "assistant", content: "second answer") # same role — invalid
    ]
    agent = WritingAgent.new(system: "test", history: history, message: "current")

    assert_raises(ArgumentError,
      "consecutive assistant→assistant messages are equally invalid and must raise") do
      agent.complete
    end
  end

  test "well-formed alternating history does not raise" do
    history = [
      HistoryMsg.new(role: "user",      content: "q1"),
      HistoryMsg.new(role: "assistant", content: "a1"),
      HistoryMsg.new(role: "user",      content: "q2"),
      HistoryMsg.new(role: "assistant", content: "a2")
    ]
    agent = WritingAgent.new(system: "test", history: history, message: "q3")

    assert_nothing_raised { agent.send(:build_messages) }
  end

  test "context exchange ending in assistant + first history message as user does not raise" do
    # Context exchange ends with assistant: "Understood..."
    # History starting with user is still valid (alternating from context assistant).
    history = [
      HistoryMsg.new(role: "user",      content: "first question after context"),
      HistoryMsg.new(role: "assistant", content: "answer")
    ]
    agent = WritingAgent.new(
      system:  "test",
      context: "the document",
      history: history,
      message: "next question"
    )

    assert_nothing_raised { agent.send(:build_messages) }
  end

  # ── Test 2: Empty message content ────────────────────────────────────────────
  # Anthropic rejects messages with content: nil or content: "".
  # build_messages currently calls msg.content.to_s — nil becomes "".
  # The resulting { role: "user", content: "" } silently reaches the provider and
  # causes a 400. Guard: skip history messages whose content is blank after coercion.
  #
  # VERDICT: FIX — build_messages now skips history messages with blank content.

  test "history message with nil content is excluded — nil.to_s produces blank that Anthropic rejects" do
    history = [
      HistoryMsg.new(role: "user",      content: nil),    # nil → "" after .to_s
      HistoryMsg.new(role: "assistant", content: "response")
    ]
    agent = WritingAgent.new(system: "test", history: history, message: "current")
    messages = agent.send(:build_messages)

    blank = messages.select { |m| m[:content].blank? }
    assert blank.empty?,
      "messages with blank content must not reach the provider — found: #{blank.inspect}"
  end

  test "history message with empty string content is excluded — Anthropic rejects content: ''" do
    history = [
      HistoryMsg.new(role: "user",      content: ""),
      HistoryMsg.new(role: "assistant", content: "response")
    ]
    agent = WritingAgent.new(system: "test", history: history, message: "current")
    messages = agent.send(:build_messages)

    blank = messages.select { |m| m[:content].blank? }
    assert blank.empty?,
      "empty string content must not appear as a message — Anthropic rejects content: ''"
  end

  test "history message with blank content is omitted but its pair is still present" do
    # Only the blank message is dropped; the subsequent assistant response
    # is still included so the surrounding conversation stays coherent.
    history = [
      HistoryMsg.new(role: "user",      content: "valid question"),
      HistoryMsg.new(role: "assistant", content: ""),               # blank — must be excluded
      HistoryMsg.new(role: "user",      content: "another question")
    ]
    agent = WritingAgent.new(system: "test", history: history, message: "current")
    messages = agent.send(:build_messages)

    contents = messages.map { |m| m[:content] }
    assert_includes contents, "valid question",    "non-blank messages must survive"
    assert_includes contents, "another question",  "non-blank messages must survive"
    refute_includes contents, "",                  "blank content must be excluded"
  end

  # ── Test 3: Very long message list ───────────────────────────────────────────
  # build_messages does not truncate. 200 history messages + current = 201.
  # This is intentional — callers manage history length.
  #
  # VERDICT: DOC — all 200 pass through; no truncation, no warning.

  test "200-message history passes through entirely — no silent truncation (DOC: intentional caller responsibility)" do
    history = 100.times.flat_map do |i|
      [
        HistoryMsg.new(role: "user",      content: "question #{i}"),
        HistoryMsg.new(role: "assistant", content: "answer #{i}")
      ]
    end

    agent    = WritingAgent.new(system: "test", history: history, message: "current")
    messages = agent.send(:build_messages)

    # 200 history messages + 1 current message
    assert_equal 201, messages.length,
      "build_messages must pass all history through — callers manage context length, not the gem"
  end

  # ── Test 4: Context exchange + history ordering ───────────────────────────────
  # The contract: context exchange (user: doc, assistant: ack) is prepended,
  # then history messages, then the current user message. Verify this order holds
  # when all three are present — wrong order causes coherence and role-sequence issues.
  #
  # VERDICT: PASS — ordering is correct.

  test "context exchange prepended before history, current message appended last" do
    history = [
      HistoryMsg.new(role: "user",      content: "past question"),
      HistoryMsg.new(role: "assistant", content: "past answer")
    ]
    agent = WritingAgent.new(
      system:  "test",
      context: "the document",
      history: history,
      message: "current question"
    )
    messages = agent.send(:build_messages)

    # Expected: [user:doc, assistant:ack, user:past_q, assistant:past_a, user:current]
    assert_equal 5, messages.length, "expected 5 messages (2 context + 2 history + 1 current)"
    assert_equal "user",        messages[0][:role],    "index 0 must be context user message"
    assert_equal "the document", messages[0][:content], "index 0 content must be the context"
    assert_equal "assistant",   messages[1][:role],    "index 1 must be context assistant ack"
    assert_equal "user",        messages[2][:role],    "index 2 must be first history user"
    assert_equal "past question", messages[2][:content]
    assert_equal "assistant",   messages[3][:role],    "index 3 must be history assistant"
    assert_equal "user",        messages[4][:role],    "index 4 (last) must be current user message"
    assert_includes messages[4][:content], "current question"
  end

  test "no context — history and current message without any context exchange prepended" do
    history = [
      HistoryMsg.new(role: "user",      content: "q"),
      HistoryMsg.new(role: "assistant", content: "a")
    ]
    agent    = WritingAgent.new(system: "test", history: history, message: "current")
    messages = agent.send(:build_messages)

    # No context exchange — 2 history + 1 current
    assert_equal 3, messages.length
    assert_equal "q",       messages[0][:content]
    assert_equal "a",       messages[1][:content]
    assert_includes messages[2][:content], "current"
  end

  # ── Test 5: File attachment in current message + history attachment ───────────
  # Both file_content on the current message and attached_file_content on a history
  # message must appear in the correct positions in the messages array.
  #
  # VERDICT: PASS — both attachments appear correctly.

  test "history attachment and current file attachment both appear in correct message positions" do
    history = [
      HistoryMsg.new(
        role:                  "user",
        content:               "analyze this",
        attached_file_content: "history file body",
        attached_file_name:    "history.txt"
      ),
      HistoryMsg.new(role: "assistant", content: "here is my analysis")
    ]
    agent = WritingAgent.new(
      system:       "test",
      history:      history,
      message:      "now rewrite",
      file_name:    "current.txt",
      file_content: "current file body"
    )
    messages = agent.send(:build_messages)

    # History message: file content prepended before the user text
    history_msg = messages[0]
    assert_includes history_msg[:content], "Attached file — history.txt:",
      "history attachment header must be present"
    assert_includes history_msg[:content], "history file body",
      "history file content must be present"
    assert_includes history_msg[:content], "analyze this",
      "original history message content must still be present"

    # Current message: file content and message both present
    current_msg = messages.last
    assert_equal "user", current_msg[:role]
    assert_includes current_msg[:content], "Attached file — current.txt:",
      "current file attachment header must be in the last message"
    assert_includes current_msg[:content], "current file body",
      "current file content must be in the last message"
    assert_includes current_msg[:content], "now rewrite",
      "current message text must still be present"
  end

  test "history message without attachment has no spurious file prefix" do
    history = [
      HistoryMsg.new(role: "user", content: "clean message"),
      HistoryMsg.new(role: "assistant", content: "response")
    ]
    agent    = WritingAgent.new(system: "test", history: history, message: "current")
    messages = agent.send(:build_messages)

    refute_includes messages[0][:content], "Attached file",
      "message without attachment must not have 'Attached file' prefix"
    assert_equal "clean message", messages[0][:content]
  end

  # ── Test 6: Focus text ordering ───────────────────────────────────────────────
  # focus: text must appear BEFORE message: text in the last user message.
  # Wrong order degrades generation quality (the model sees instruction before selection).
  #
  # VERDICT: PASS — focus is prepended before message.

  test "focus text appears before message text in the final user message" do
    agent = WritingAgent.new(
      system:  "test",
      focus:   "the selected paragraph",
      message: "please improve this"
    )
    messages = agent.send(:build_messages)

    last_msg    = messages.last
    focus_pos   = last_msg[:content].index("the selected paragraph")
    message_pos = last_msg[:content].index("please improve this")

    refute_nil focus_pos,   "focus text must appear in the last user message"
    refute_nil message_pos, "message text must appear in the last user message"
    assert focus_pos < message_pos,
      "focus must precede message — focus_pos=#{focus_pos}, message_pos=#{message_pos}\ncontent: #{last_msg[:content].inspect}"
  end

  test "focus text is labelled with 'Selected text:' prefix" do
    agent    = WritingAgent.new(system: "test", focus: "the selection", message: "do something")
    messages = agent.send(:build_messages)

    assert_includes messages.last[:content], "Selected text:\nthe selection",
      "focus must be labelled with 'Selected text:' header"
  end

  test "message with no focus has no 'Selected text' header in last message" do
    agent    = WritingAgent.new(system: "test", message: "just a message")
    messages = agent.send(:build_messages)

    refute_includes messages.last[:content], "Selected text",
      "without focus: there must be no 'Selected text' prefix in the last message"
  end

  test "focus with no message produces no messages at all (message block is gated on @message.present?)" do
    # @message is nil → the final user block is not appended
    agent    = WritingAgent.new(system: "test", focus: "selected text")
    messages = agent.send(:build_messages)

    assert_empty messages,
      "focus without message produces no messages — the message block is gated on @message.present?"
  end

  # ── Test 7: Missing role in history ──────────────────────────────────────────
  # A history message with role: nil. nil.to_s → "" → { role: "", content: "..." }
  # silently reaches the provider and causes a 400 validation error.
  # build_messages must detect and raise on blank roles.
  #
  # VERDICT: FIX — build_messages now raises ArgumentError on blank role.

  test "history message with nil role raises ArgumentError — blank role reaches provider as role: ''" do
    history = [HistoryMsg.new(role: nil, content: "some content")]
    agent   = WritingAgent.new(system: "test", history: history, message: "current")

    error = assert_raises(ArgumentError,
      "nil role must raise ArgumentError — role: '' causes Anthropic 400") do
      agent.complete
    end
    assert_match(/role/i, error.message,
      "error message must mention 'role' — got: #{error.message.inspect}")
  end

  test "history message with blank string role raises ArgumentError" do
    history = [HistoryMsg.new(role: "", content: "some content")]
    agent   = WritingAgent.new(system: "test", history: history, message: "current")

    assert_raises(ArgumentError,
      "blank string role must also raise — it is equally invalid") do
      agent.complete
    end
  end

  test "history message with valid roles 'user' and 'assistant' does not raise" do
    history = [
      HistoryMsg.new(role: "user",      content: "q"),
      HistoryMsg.new(role: "assistant", content: "a")
    ]
    agent = WritingAgent.new(system: "test", history: history, message: "next")
    assert_nothing_raised { agent.send(:build_messages) }
  end

  # ── Test 8: System prompt with special characters ─────────────────────────────
  # System prompt containing \n, <xml>, and "quotes" must survive intact through
  # build_system_blocks into the Anthropic text block without any escaping or mangling.
  #
  # VERDICT: PASS — text is passed as-is; no transformation occurs.

  test "system prompt with newlines, XML tags, and quotes survives build_system_blocks intact" do
    special_system = "You are a writer.\nFocus on: <xml>content</xml>\nSay \"hello world\"."
    provider  = ActiveAI::Provider::Anthropic.new
    canonical = {
      system:       special_system,
      skills:       [],
      source_files: [],
      messages:     [],
      cacheable:    {}
    }

    blocks       = provider.send(:build_system_blocks, canonical)
    system_block = blocks.find { |b| b[:text] == special_system }

    refute_nil system_block,
      "system text with special characters must be preserved exactly — blocks: #{blocks.inspect}"
  end

  test "system prompt with ONLY special characters still appears as a single block" do
    provider  = ActiveAI::Provider::Anthropic.new
    canonical = {
      system:       "<instructions>\n\"do this\" & 'that'\n</instructions>",
      skills:       [],
      source_files: [],
      messages:     [],
      cacheable:    {}
    }

    blocks = provider.send(:build_system_blocks, canonical)
    assert_equal 1, blocks.length,
      "one system block expected for a non-blank system with special chars"
    assert_equal canonical[:system], blocks.first[:text]
  end

  # ── Test 9: Skills with nil content ──────────────────────────────────────────
  # A skill object where content returns nil. build_params serializes this as
  # { id: ..., name: ..., content: nil } in canonical[:skills].
  # build_system_blocks then produces { type: "text", text: nil } — Anthropic rejects nil text.
  # Guard: skip nil-content skill blocks in build_system_blocks.
  #
  # VERDICT: FIX — build_system_blocks now skips skills whose content is nil/blank.

  test "skill with nil content produces no text: nil block in build_system_blocks" do
    nil_skill = Struct.new(:id, :name, :content, keyword_init: true).new(
      id: 1, name: "empty_skill", content: nil
    )
    agent    = WritingAgent.new(system: "test", skills: [nil_skill], message: "hi")
    provider = ActiveAI::Provider::Anthropic.new
    canonical = agent.to_canonical_params

    blocks = provider.send(:build_system_blocks, canonical)

    nil_text_blocks = blocks.select { |b| b[:text].nil? }
    assert nil_text_blocks.empty?,
      "skill with nil content must not produce text: nil in system blocks — Anthropic rejects nil text: #{nil_text_blocks.inspect}"
  end

  test "skill with empty string content produces no blank text block" do
    blank_skill = Struct.new(:id, :name, :content, keyword_init: true).new(
      id: 2, name: "blank_skill", content: ""
    )
    agent    = WritingAgent.new(system: "test", skills: [blank_skill], message: "hi")
    provider = ActiveAI::Provider::Anthropic.new
    canonical = agent.to_canonical_params

    blocks = provider.send(:build_system_blocks, canonical)

    blank_text_blocks = blocks.select { |b| b[:text].blank? }
    assert blank_text_blocks.empty?,
      "skill with empty string content must produce no blank text block — Anthropic rejects text: ''"
  end

  test "skill with valid content still appears as a system block" do
    good_skill = Struct.new(:id, :name, :content, keyword_init: true).new(
      id: 3, name: "good_skill", content: "Tone guidance: be concise."
    )
    agent    = WritingAgent.new(system: "test", skills: [good_skill], message: "hi")
    provider = ActiveAI::Provider::Anthropic.new
    canonical = agent.to_canonical_params

    blocks = provider.send(:build_system_blocks, canonical)

    skill_block = blocks.find { |b| b[:text] == "Tone guidance: be concise." }
    refute_nil skill_block,
      "skill with valid content must produce a system block — blocks: #{blocks.inspect}"
  end

  test "mixed nil and valid skills: nil is excluded, valid is present" do
    nil_skill  = Struct.new(:id, :name, :content, keyword_init: true).new(id: 1, name: "nil",   content: nil)
    good_skill = Struct.new(:id, :name, :content, keyword_init: true).new(id: 2, name: "valid", content: "Be helpful.")

    agent    = WritingAgent.new(system: "test", skills: [nil_skill, good_skill], message: "hi")
    provider = ActiveAI::Provider::Anthropic.new
    canonical = agent.to_canonical_params

    blocks = provider.send(:build_system_blocks, canonical)

    refute blocks.any? { |b| b[:text].nil? },  "no nil text blocks must appear"
    assert blocks.any? { |b| b[:text] == "Be helpful." }, "valid skill block must still be present"
  end

  # ── Test 10: source_files with non-responding objects ─────────────────────────
  # If source_files contains objects that don't respond to .name or .content,
  # build_system_blocks raises NoMethodError. This is acceptable (it raises
  # clearly) — no silent bad data. No fix needed; behavior is documented.
  #
  # VERDICT: DOC — NoMethodError points directly to the bad object.
  # If a typed ActiveAI error is desired, add a guard around the map.

  test "source_files with objects lacking .name raises NoMethodError (DOC: clear error, not typed)" do
    bad_source = Object.new  # does not respond to .name or .content

    agent    = WritingAgent.new(system: "test", source_files: [bad_source], message: "hi")
    provider = ActiveAI::Provider::Anthropic.new
    canonical = agent.to_canonical_params

    # source_files.any? returns true (array has one element), triggering the map block
    # sf.name raises NoMethodError on the bare Object instance
    assert_raises(NoMethodError,
      "source_files missing .name/.content raises NoMethodError (DOC: clear but not a typed ActiveAI error)") do
      provider.send(:build_system_blocks, canonical)
    end
  end

  test "well-formed source_files struct works without error" do
    SourceFile = Struct.new(:name, :content) unless defined?(SourceFile)
    sf = SourceFile.new("notes.md", "# Notes\nImportant context.")

    agent    = WritingAgent.new(system: "test", source_files: [sf], message: "hi")
    provider = ActiveAI::Provider::Anthropic.new
    canonical = agent.to_canonical_params

    blocks = provider.send(:build_system_blocks, canonical)

    file_block = blocks.find { |b| b[:text]&.include?("=== notes.md ===") }
    refute_nil file_block, "well-formed source file must produce a system block"
    assert_includes file_block[:text], "Important context."
  end
end
