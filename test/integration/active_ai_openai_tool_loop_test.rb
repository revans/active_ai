require "test_helper"

# Adversarial integration tests for the OpenAI/XAI tool call loop.
#
# Think of the OpenAI tool call wire protocol as a three-act play:
#   Act 1 — the model names the tool it wants to call (arrives as streaming deltas).
#   Act 2 — your code calls the tool and gets a result.
#   Act 3 — you send the result back in the specific format OpenAI expects, then
#            the model produces a final text response.
#
# The active_ai gem talks Anthropic-dialect internally. To support OpenAI tools,
# three translations are needed:
#   T1 — tool definitions:  Anthropic input_schema: → OpenAI parameters: wrapped in type:"function"
#   T2 — tool call parsing: OpenAI JSON-string arguments → Hash before tool.call(**args)
#   T3 — tool loop messages: OpenAI wants { role:"tool" } not { role:"user", content:[...] }
#
# Strategy: stub client.chat directly on provider instances — no real API calls.
#
# VERDICT legend:
#   PASS  — existing code handles it correctly
#   FIX   — a code change was required

class OpenAIToolLoopTest < ActiveSupport::TestCase

  def canonical(messages: [{ role: "user", content: "go" }], tools: [])
    {
      model:        "gpt-4.1",
      max_tokens:   1024,
      system:       "test system",
      skills:       [],
      source_files: [],
      messages:     messages,
      cacheable:    {},
      tools:        tools
    }
  end

  # Injects a fake client directly onto a provider instance.
  def stub_openai_chat(provider, &impl)
    fake_client = Object.new
    fake_client.define_singleton_method(:chat, &impl)
    provider.instance_variable_set(:@client, fake_client)
  end

  # Returns an array of OpenAI streaming chunks that represent one complete
  # tool call — the same pattern OpenAI's API sends over SSE.
  # Think of it as the model saying "I want to call TOOL with ARGS" in pieces.
  def openai_tool_call_chunks(id:, name:, arguments:)
    [
      # Chunk 1: establishes the call id and function name
      { "id" => "chatcmpl-abc", "choices" => [{
          "delta" => { "content" => nil, "tool_calls" => [{
            "index" => 0, "id" => id, "type" => "function",
            "function" => { "name" => name, "arguments" => "" }
          }] },
          "finish_reason" => nil
      }], "usage" => nil },
      # Chunk 2: delivers argument JSON fragment
      { "id" => "chatcmpl-abc", "choices" => [{
          "delta" => { "tool_calls" => [{
            "index" => 0, "function" => { "arguments" => arguments }
          }] },
          "finish_reason" => nil
      }], "usage" => nil },
      # Chunk 3: signals the call is complete
      { "id" => "chatcmpl-abc", "choices" => [{
          "delta" => {}, "finish_reason" => "tool_calls"
      }], "usage" => nil },
      # Chunk 4: usage summary
      { "id" => "chatcmpl-abc", "choices" => [],
        "usage" => { "prompt_tokens" => 10, "completion_tokens" => 5 } }
    ]
  end

  def openai_text_chunks(text, id: "chatcmpl-txt")
    [
      { "id" => id, "choices" => [{ "delta" => { "content" => text }, "finish_reason" => nil }], "usage" => nil },
      { "id" => id, "choices" => [{ "delta" => {}, "finish_reason" => "stop" }], "usage" => nil },
      { "id" => id, "choices" => [], "usage" => { "prompt_tokens" => 5, "completion_tokens" => 3 } }
    ]
  end

  # ── 1. Tool definition format conversion ────────────────────────────────────
  # VERDICT: FIX — OpenAI#build_params sent no tools at all.
  # Anthropic uses input_schema:; OpenAI uses parameters: inside type:"function".

  test "OpenAI build_params converts Anthropic tool definitions to OpenAI format" do
    provider = ActiveAI::Provider::OpenAI.new
    tool_def = {
      name:         "web_search",
      description:  "Search the web",
      input_schema: {
        type:       "object",
        properties: { query: { type: "string", description: "The query" } },
        required:   ["query"]
      }
    }
    params = provider.send(:build_params, canonical(tools: [tool_def]))

    assert params.key?(:tools),
      "build_params must include :tools in the OpenAI params when tools are present"
    tool = params[:tools].first
    assert_equal "function", tool[:type],
      "each tool must be wrapped with type: 'function' — OpenAI rejects bare tool objects"
    assert_equal "web_search",  tool[:function][:name]
    assert_equal "Search the web", tool[:function][:description]
    assert_equal "object", tool[:function][:parameters][:type],
      "input_schema must be remapped to :parameters — Anthropic and OpenAI use different keys"
    assert tool[:function][:parameters].key?(:properties)
    assert tool[:function][:parameters].key?(:required)
  end

  test "OpenAI build_params omits :tools key when no tools are declared" do
    provider = ActiveAI::Provider::OpenAI.new
    params   = provider.send(:build_params, canonical(tools: []))
    refute params.key?(:tools),
      "build_params must not include a :tools key when the canonical has no tools"
  end

  # ── 2. Streaming chunk accumulation ──────────────────────────────────────────
  # VERDICT: FIX — handle_chunk did not read choices[0].delta.tool_calls.
  # OpenAI sends tool call data as deltas across multiple chunks, like how a
  # streaming HTTP response sends body bytes one chunk at a time.

  test "handle_chunk accumulates tool call id and name from first delta chunk" do
    provider    = ActiveAI::Provider::OpenAI.new
    accumulator = {}
    chunk = {
      "choices" => [{
        "delta"       => { "tool_calls" => [{ "index" => 0, "id" => "call_xyz",
                            "type" => "function",
                            "function" => { "name" => "lookup", "arguments" => "" } }] },
        "finish_reason" => nil
      }],
      "usage" => nil
    }
    provider.send(:handle_chunk, chunk, accumulator) { }

    assert accumulator.key?("tool_calls"),
      "accumulator must have 'tool_calls' key after first tool call delta"
    tc = accumulator["tool_calls"][0]
    assert_equal "call_xyz", tc["id"]
    assert_equal "lookup",   tc.dig("function", "name")
  end

  test "handle_chunk concatenates argument fragments across multiple chunks" do
    provider    = ActiveAI::Provider::OpenAI.new
    accumulator = {}

    chunks = [
      { "choices" => [{ "delta" => { "tool_calls" => [{ "index" => 0, "id" => "call_f",
          "type" => "function", "function" => { "name" => "calc", "arguments" => "" } }] },
          "finish_reason" => nil }], "usage" => nil },
      { "choices" => [{ "delta" => { "tool_calls" => [{ "index" => 0,
          "function" => { "arguments" => '{"a":' } }] }, "finish_reason" => nil }], "usage" => nil },
      { "choices" => [{ "delta" => { "tool_calls" => [{ "index" => 0,
          "function" => { "arguments" => "1}" } }] }, "finish_reason" => nil }], "usage" => nil }
    ]
    chunks.each { |c| provider.send(:handle_chunk, c, accumulator) { } }

    args = accumulator.dig("tool_calls", 0, "function", "arguments")
    assert_equal '{"a":1}', args,
      "argument fragments must be concatenated — treat each chunk like a TCP packet"
  end

  test "handle_chunk does not corrupt accumulator when chunk has no tool_calls" do
    provider    = ActiveAI::Provider::OpenAI.new
    accumulator = {}
    text_chunk  = { "choices" => [{ "delta" => { "content" => "hello" }, "finish_reason" => nil }], "usage" => nil }
    provider.send(:handle_chunk, text_chunk, accumulator) { }

    refute accumulator.key?("tool_calls"),
      "a plain text chunk must not create a tool_calls key in the accumulator"
  end

  # ── 3. last_tool_calls populated and correctly shaped ────────────────────────
  # VERDICT: FIX — last_tool_calls was always [] for OpenAI.

  test "last_tool_calls is populated after streaming a tool call" do
    provider = ActiveAI::Provider::OpenAI.new
    # Capture chunks outside the block — define_singleton_method changes self,
    # making test helper methods inaccessible inside the block.
    chunks = openai_tool_call_chunks(id: "call_1", name: "lookup", arguments: '{"query":"ruby"}')
    stub_openai_chat(provider) do |parameters:|
      chunks.each { |chunk| parameters[:stream].call(chunk, nil) }
    end

    provider.stream(canonical) { }

    assert_equal 1, provider.last_tool_calls.size,
      "last_tool_calls must contain one entry after a single tool call response"
    tc = provider.last_tool_calls.first
    assert_equal "call_1", tc[:id]
    assert_equal "lookup", tc[:name]
    assert_kind_of Hash, tc[:input],
      "input must be a Hash — arguments JSON string must be parsed before storing"
  end

  test "last_tool_calls arguments are parsed from JSON string to Hash" do
    provider = ActiveAI::Provider::OpenAI.new
    chunks = openai_tool_call_chunks(id: "call_j", name: "search", arguments: '{"query":"rails"}')
    stub_openai_chat(provider) do |parameters:|
      chunks.each { |chunk| parameters[:stream].call(chunk, nil) }
    end

    provider.stream(canonical) { }

    input = provider.last_tool_calls.first[:input]
    assert_kind_of Hash, input,
      "tool input must be a parsed Hash — a raw JSON string crashes tool.call(**args)"
    assert_equal "rails", input["query"],
      "parsed input must contain the correct values from the JSON arguments"
  end

  test "last_tool_calls is empty after a text-only stream" do
    provider = ActiveAI::Provider::OpenAI.new
    text_chunks = openai_text_chunks("hello")
    stub_openai_chat(provider) do |parameters:|
      text_chunks.each { |c| parameters[:stream].call(c, nil) }
    end

    provider.stream(canonical) { }

    assert_empty provider.last_tool_calls,
      "last_tool_calls must be [] after a stream that produces only text — no tool call"
  end

  test "last_tool_calls is reset to [] at the start of each new stream call" do
    provider = ActiveAI::Provider::OpenAI.new

    # First call: produces a tool call
    first_chunks = openai_tool_call_chunks(id: "call_r1", name: "lookup", arguments: "{}")
    stub_openai_chat(provider) do |parameters:|
      first_chunks.each { |chunk| parameters[:stream].call(chunk, nil) }
    end
    provider.stream(canonical) { }
    assert_equal 1, provider.last_tool_calls.size, "first call must populate last_tool_calls"

    # Second call: text only — last_tool_calls must be cleared
    second_chunks = openai_text_chunks("done")
    stub_openai_chat(provider) do |parameters:|
      second_chunks.each { |c| parameters[:stream].call(c, nil) }
    end
    provider.stream(canonical) { }
    assert_empty provider.last_tool_calls,
      "last_tool_calls must be reset to [] at the start of each stream call — no stale state"
  end

  # ── 4. format_assistant_turn — OpenAI format ─────────────────────────────────
  # VERDICT: FIX — the base.rb loop hardcoded Anthropic format for the assistant turn.
  # OpenAI requires: { role: "assistant", content: nil, tool_calls: [...] }
  # Anthropic uses:  { role: "assistant", content: [{ type: "tool_use", ... }] }

  test "format_assistant_turn on OpenAI returns content: nil and tool_calls array" do
    provider   = ActiveAI::Provider::OpenAI.new
    tool_calls = [{ id: "call_fmt", name: "lookup", input: { "q" => "test" } }]
    msg        = provider.format_assistant_turn([], tool_calls)

    assert_equal "assistant", msg[:role]
    assert_nil msg[:content],
      "OpenAI assistant turn must have content: nil when tool calls are present — " \
      "OpenAI rejects content: [...] on tool call turns"
    assert_kind_of Array, msg[:tool_calls],
      "OpenAI assistant turn must include :tool_calls array"
    assert_equal "call_fmt", msg[:tool_calls].first["id"]
    assert_equal "lookup",   msg[:tool_calls].first.dig("function", "name")
  end

  test "format_assistant_turn re-encodes input back to JSON string for OpenAI" do
    provider   = ActiveAI::Provider::OpenAI.new
    tool_calls = [{ id: "call_enc", name: "search", input: { "q" => "test" } }]
    msg        = provider.format_assistant_turn([], tool_calls)
    args       = msg[:tool_calls].first.dig("function", "arguments")

    assert_kind_of String, args,
      "OpenAI tool_calls function.arguments must be a JSON-encoded string, not a Hash"
    assert_equal({ "q" => "test" }, JSON.parse(args))
  end

  # ── 5. format_tool_result_messages — OpenAI format ───────────────────────────
  # VERDICT: FIX — the base.rb loop used Anthropic's role:user wrapper.
  # OpenAI format: individual { role: "tool", tool_call_id: ..., content: ... }
  # Anthropic format: one { role: "user", content: [{ type: "tool_result", ... }] }
  # Sending Anthropic format to OpenAI → 400 Bad Request.

  test "format_tool_result_messages on OpenAI returns individual role:tool messages" do
    provider     = ActiveAI::Provider::OpenAI.new
    tool_results = [
      { type: "tool_result", tool_use_id: "call_a", content: "result A" },
      { type: "tool_result", tool_use_id: "call_b", content: "result B" }
    ]
    msgs = provider.format_tool_result_messages(tool_results)

    assert_equal 2, msgs.size,
      "OpenAI must receive one role:tool message per tool result — not a batch wrapper"
    assert_equal "tool",     msgs[0][:role]
    assert_equal "call_a",   msgs[0][:tool_call_id]
    assert_equal "result A", msgs[0][:content]
    assert_equal "tool",     msgs[1][:role]
    assert_equal "call_b",   msgs[1][:tool_call_id]
    assert_equal "result B", msgs[1][:content]
  end

  test "format_tool_result_messages does not produce a role:user wrapper" do
    provider     = ActiveAI::Provider::OpenAI.new
    tool_results = [{ type: "tool_result", tool_use_id: "call_z", content: "z" }]
    msgs = provider.format_tool_result_messages(tool_results)

    user_wrapper = msgs.find { |m| m[:role] == "user" }
    assert_nil user_wrapper,
      "OpenAI format must NOT wrap results in a role:user message — that is Anthropic format"
  end

  # ── 6. Anthropic format stays unchanged (regression) ─────────────────────────
  # The base.rb change routes through provider methods, so we verify Anthropic
  # still produces its own correct format.
  # VERDICT: PASS (once the provider base methods exist)

  test "Anthropic format_assistant_turn returns content array — no tool_calls key" do
    provider         = ActiveAI::Provider::Anthropic.new
    assistant_content = [{ type: "tool_use", id: "call_ac", name: "lookup", input: {} }]
    msg              = provider.format_assistant_turn(assistant_content, [])

    assert_equal "assistant", msg[:role]
    assert_equal assistant_content, msg[:content],
      "Anthropic format_assistant_turn must return { role: assistant, content: [...] }"
    refute msg.key?(:tool_calls),
      "Anthropic format_assistant_turn must not produce a :tool_calls key"
  end

  test "Anthropic format_tool_result_messages wraps all results in one role:user message" do
    provider     = ActiveAI::Provider::Anthropic.new
    tool_results = [
      { type: "tool_result", tool_use_id: "call_ar", content: "result" }
    ]
    msgs = provider.format_tool_result_messages(tool_results)

    assert_equal 1, msgs.size,
      "Anthropic must produce exactly one role:user message for all tool results"
    assert_equal "user", msgs.first[:role]
    assert_kind_of Array, msgs.first[:content],
      "Anthropic tool result content must be an Array of tool_result blocks"
  end

  # ── 7. Full agentic loop with stubbed OpenAI provider ────────────────────────
  # VERDICT: FIX — the base.rb loop used Anthropic wire format for history messages.
  # Fix: base.rb delegates to provider#format_assistant_turn and
  # format_tool_result_messages, which return the correct format per provider.

  test "full agentic loop: OpenAI single tool call then final text" do
    lookup_tool = Class.new(ApplicationTool) do
      tool_name "openai_loop_test"
      description "Looks up something"
      param :query, type: :string, description: "What to look up"
      def call(query:) = "result for #{query}"
    end

    agent_class = Class.new(WritingAgent) do
      provider :openai
      tools lookup_tool
    end
    agent = agent_class.new(system: "test", message: "find ruby")

    # Stub provider_instance to return a real OpenAI provider with stream overridden
    call_count = 0
    agent.define_singleton_method(:provider_instance) do
      call_count += 1
      prov = ActiveAI::Provider::OpenAI.new
      if call_count == 1
        prov.define_singleton_method(:stream) do |_params, &_block|
          @last_tool_calls        = [{ id: "call_oa1", name: "openai_loop_test", input: { "query" => "ruby" } }]
          @last_assistant_content = @last_tool_calls.dup
        end
      else
        prov.define_singleton_method(:stream) do |_params, &block|
          block.call("Here is what I found about ruby")
          @last_tool_calls        = []
          @last_assistant_content = []
        end
      end
      prov
    end

    result = agent.complete

    assert_equal "Here is what I found about ruby", result,
      "agentic loop must return the final text after one tool call turn"
    assert_equal 1, agent.last_tool_call_results.size,
      "exactly one tool call must be recorded"
    assert_equal "result for ruby", agent.last_tool_call_results.first[:result],
      "tool result must be the return value of the registered tool"
  end

  test "messages sent to OpenAI on second turn use role:tool format" do
    spy_tool = Class.new(ApplicationTool) do
      tool_name "openai_msg_spy_test"
      description "Spy"
      def call(**) = "spied"
    end

    agent_class = Class.new(WritingAgent) do
      provider :openai
      tools spy_tool
    end
    agent = agent_class.new(system: "test", message: "go")

    captured_second_messages = nil
    call_count = 0

    agent.define_singleton_method(:provider_instance) do
      call_count += 1
      prov = ActiveAI::Provider::OpenAI.new
      if call_count == 1
        prov.define_singleton_method(:stream) do |_params, &_block|
          @last_tool_calls        = [{ id: "call_spy1", name: "openai_msg_spy_test", input: {} }]
          @last_assistant_content = @last_tool_calls.dup
        end
      else
        prov.define_singleton_method(:stream) do |params, &block|
          captured_second_messages = params[:messages]
          block.call("done")
          @last_tool_calls        = []
          @last_assistant_content = []
        end
      end
      prov
    end

    agent.complete

    assert_not_nil captured_second_messages,
      "provider must be called a second time after tool execution"

    # Tool result must be role:tool, NOT role:user with content array
    tool_msg = captured_second_messages.find { |m| m[:role] == "tool" }
    assert_not_nil tool_msg,
      "second-turn messages must include a { role: 'tool' } message — OpenAI requires this"
    assert_equal "call_spy1", tool_msg[:tool_call_id]
    assert_equal "spied",     tool_msg[:content]

    # Must NOT have a Anthropic-style role:user wrapper around tool results
    anthropic_wrapper = captured_second_messages.find { |m| m[:role] == "user" && m[:content].is_a?(Array) }
    assert_nil anthropic_wrapper,
      "OpenAI second turn must NOT have an Anthropic-style { role:'user', content:[...] } wrapper"

    # Assistant turn must use OpenAI format with tool_calls key
    assistant_msg = captured_second_messages.find { |m| m[:role] == "assistant" && m.key?(:tool_calls) }
    assert_not_nil assistant_msg,
      "second-turn messages must include an OpenAI-format assistant message with :tool_calls key"
  end

  # ── 8. Two consecutive tool calls then final text ────────────────────────────
  # Multi-turn: ensures the loop handles multiple iterations cleanly.
  # VERDICT: FIX (same fix as the single-turn test)

  test "two consecutive OpenAI tool calls then final text — loop handles both" do
    counter = 0
    count_tool = Class.new(ApplicationTool) do
      tool_name "openai_two_turn_test"
      description "Counts"
      def call(**) = "counted"
    end

    agent_class = Class.new(WritingAgent) do
      provider :openai
      tools count_tool
    end
    agent = agent_class.new(system: "test", message: "go")

    call_count = 0
    agent.define_singleton_method(:provider_instance) do
      call_count += 1
      prov = ActiveAI::Provider::OpenAI.new
      case call_count
      when 1, 2
        prov.define_singleton_method(:stream) do |_params, &_block|
          @last_tool_calls        = [{ id: "call_tt#{call_count}", name: "openai_two_turn_test", input: {} }]
          @last_assistant_content = @last_tool_calls.dup
        end
      else
        prov.define_singleton_method(:stream) do |_params, &block|
          block.call("both tools done")
          @last_tool_calls        = []
          @last_assistant_content = []
        end
      end
      prov
    end

    result = agent.complete

    assert_equal "both tools done", result,
      "loop must produce final text after two tool call iterations"
    assert_equal 2, agent.last_tool_call_results.size,
      "exactly two tool call results must be recorded across both iterations"
  end
end
