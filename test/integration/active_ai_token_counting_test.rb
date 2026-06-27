require "test_helper"

# Adversarial integration tests for token usage tracking across the agentic loop.
# All tests stub provider_instance — no real API calls are made.
#
# VERDICT key:
#   PASS   — existing code handles it correctly; test documents the behavior
#   FIX    — a code change was required; see section comment for details
class ActiveAITokenCountingTest < ActiveSupport::TestCase
  include ActiveAI::TestHelper

  # Build a provider stub object. Must be created OUTSIDE define_singleton_method
  # because define_singleton_method changes self to the receiver (the agent),
  # so local helper methods become unreachable inside the block.
  # Capture the provider in a local variable and close over it instead.
  def build_provider(usage:, response: nil, tool_calls: [])
    prov = Object.new
    if tool_calls.any?
      the_calls = tool_calls
      prov.define_singleton_method(:stream)                 { |_params, &_block| }
      prov.define_singleton_method(:last_tool_calls)        { the_calls }
      prov.define_singleton_method(:last_assistant_content) do
        the_calls.map { |tc| { type: "tool_use", id: tc[:id], name: tc[:name], input: tc[:input] } }
      end
    else
      the_response = response
      prov.define_singleton_method(:stream)                 { |_params, &block| block.call(the_response.to_s) if the_response }
      prov.define_singleton_method(:last_tool_calls)        { [] }
      prov.define_singleton_method(:last_assistant_content) { [] }
    end
    the_usage = usage
    prov.define_singleton_method(:last_usage)                      { the_usage }
    prov.define_singleton_method(:format_assistant_turn)           { |c, _| { role: "assistant", content: c } }
    prov.define_singleton_method(:format_tool_result_messages)     { |r| [{ role: "user", content: r }] }
    prov
  end

  # ── 1. last_usage after single-turn ─────────────────────────────────────────
  # VERDICT: PASS — Base#last_usage delegates to @last_provider_instance&.last_usage.
  # On a no-tool-call stream, the agentic loop runs exactly once and
  # @last_provider_instance holds the single provider receipt.
  test "last_usage after single-turn returns the provider usage hash with the right shape" do
    agent = WritingAgent.new(system: "test", message: "hello")
    prov  = build_provider(usage: { input_tokens: 100, output_tokens: 25 }, response: "hi")
    agent.define_singleton_method(:provider_instance) { prov }

    agent.stream { }

    refute_nil agent.last_usage, "last_usage must not be nil after a completed stream call"
    assert_equal 100, agent.last_usage[:input_tokens],  "input_tokens must match the provider's reported value"
    assert_equal 25,  agent.last_usage[:output_tokens], "output_tokens must match the provider's reported value"
  end

  test "last_usage shape accepts the full breakdown a real Anthropic provider returns" do
    full_usage = {
      input_tokens:          50,
      output_tokens:         12,
      cache_creation_tokens: 0,
      cache_read_tokens:     30,
      stop_reason:           "end_turn",
      provider_request_id:   "req_abc123"
    }
    agent = WritingAgent.new(system: "test", message: "hello")
    prov  = build_provider(usage: full_usage, response: "ok")
    agent.define_singleton_method(:provider_instance) { prov }

    agent.stream { }

    assert_equal 50,         agent.last_usage[:input_tokens]
    assert_equal 12,         agent.last_usage[:output_tokens]
    assert_equal 30,         agent.last_usage[:cache_read_tokens]
    assert_equal "end_turn", agent.last_usage[:stop_reason]
  end

  # ── 2. last_usage after multi-turn tool loop ─────────────────────────────────
  # VERDICT: PASS (by design) — last_usage returns ONLY the final turn's usage.
  #
  # The agentic loop reassigns @last_provider_instance on every iteration.
  # After the loop exits, it holds only the terminal provider (the one that
  # produced no tool calls and ended the loop). Earlier providers are discarded.
  #
  # Analogy: a relay race where each runner hands off the baton — at the finish
  # line you see only the last runner's result, not the combined time of all runners.
  #
  # Implication: callers who need total session token cost must accumulate
  # usage across calls themselves, or subscribe to stream.active_ai notifications.
  test "last_usage after multi-turn loop returns only the LAST turn usage — no cross-turn aggregation" do
    echo_tool = Class.new(ApplicationTool) do
      tool_name "tc_multi_turn_usage"
      description "Echo"
      def call(**) = "pong"
    end
    agent_class = Class.new(WritingAgent) { tools echo_tool }
    agent       = agent_class.new(system: "test", message: "go")

    turn_usages = [
      { input_tokens: 100, output_tokens: 5  },  # turn 1: provider requests a tool call
      { input_tokens: 115, output_tokens: 4  },  # turn 2: provider requests another tool call
      { input_tokens: 125, output_tokens: 50 }   # turn 3: provider gives the final text
    ]
    call_count = 0

    agent.define_singleton_method(:provider_instance) do
      call_count += 1
      p   = Object.new
      idx = [ call_count - 1, turn_usages.size - 1 ].min
      the_usage = turn_usages[idx]

      if call_count <= 2
        tc = [{ id: "tc_t#{call_count}", name: "tc_multi_turn_usage", input: {} }]
        p.define_singleton_method(:stream)                 { |_params, &_block| }
        p.define_singleton_method(:last_tool_calls)        { tc }
        p.define_singleton_method(:last_assistant_content) do
          tc.map { |t| { type: "tool_use", id: t[:id], name: t[:name], input: t[:input] } }
        end
      else
        p.define_singleton_method(:stream)                 { |_params, &blk| blk.call("all done") }
        p.define_singleton_method(:last_tool_calls)        { [] }
        p.define_singleton_method(:last_assistant_content) { [] }
      end
      p.define_singleton_method(:last_usage)                   { the_usage }
      p.define_singleton_method(:format_assistant_turn)        { |c, _| { role: "assistant", content: c } }
      p.define_singleton_method(:format_tool_result_messages)  { |r| [{ role: "user", content: r }] }
      p
    end

    agent.stream { }

    # last_usage is the final turn's receipt — not the sum of all three.
    assert_equal 125, agent.last_usage[:input_tokens],
      "last_usage must reflect the final turn (125), not the sum of all turns (340)"
    assert_equal 50,  agent.last_usage[:output_tokens],
      "last_usage output_tokens must be the final turn's value"

    # Explicitly document that aggregation is NOT the current contract.
    total_input = turn_usages.sum { |u| u[:input_tokens] }  # 340
    refute_equal total_input, agent.last_usage[:input_tokens],
      "340 (=100+115+125) is NOT what last_usage returns — there is no cross-turn aggregation"
  end

  # ── 3. last_usage nil before any stream call ─────────────────────────────────
  # VERDICT: PASS — @last_provider_instance is nil on a fresh agent instance.
  # Base#last_usage uses safe navigation (&.) so nil is returned, not NoMethodError.
  test "last_usage returns nil gracefully before stream has been called" do
    agent = WritingAgent.new(system: "test", message: "hello")
    # No stream call — inspect the fresh state.
    assert_nil agent.last_usage, "last_usage on a fresh agent must return nil, not raise"
  end

  test "calling last_usage before stream does not raise any exception" do
    agent = WritingAgent.new(system: "test", message: "hello")
    result = nil
    begin
      result = agent.last_usage
    rescue => e
      flunk "last_usage raised #{e.class} before stream was called: #{e.message}"
    end
    assert_nil result
  end

  # ── 4. last_usage nil when provider emits no usage data ──────────────────────
  # VERDICT: PASS — the provider is the source of truth. When it returns nil from
  # last_usage, agent.last_usage propagates nil. No defensive zero-hash is applied.
  # This mirrors how the Anthropic provider guards: `return nil unless response.usage`.
  test "last_usage returns nil when the provider reports no usage data" do
    agent = WritingAgent.new(system: "test", message: "hello")
    prov  = build_provider(usage: nil, response: "text only")
    agent.define_singleton_method(:provider_instance) { prov }

    agent.stream { }

    assert_nil agent.last_usage,
      "last_usage must return nil when provider returns nil — not a zero hash or raised error"
  end

  # ── 5. Usage across orchestrator → agent delegation ──────────────────────────
  # VERDICT: PASS (by design) — the orchestrator's last_usage reflects ONLY its own
  # LLM calls, not any sub-agent usage. Sub-agents are invoked via meta-tools that
  # call klass.run(message) — the sub-agent instance is ephemeral and its
  # @last_provider_instance is never exposed to the orchestrator.
  #
  # Analogy: a restaurant manager (orchestrator) delegates cooking to a chef (agent).
  # The manager's timeclock shows only their own hours — not the chef's.
  #
  # Implication: subscribe to stream.active_ai notifications inside the sub-agent
  # to capture sub-agent token costs. The orchestrator provides no aggregation.
  test "orchestrator last_usage reflects only its own LLM call, not sub-agent token usage" do
    delegatable_agent = Class.new(ApplicationAgent) do
      include ActiveAI::Orchestratable
      def self.name = "DelegatedTokenUsageAgent"
      description "Does work"
    end

    orch_class = Class.new(ApplicationOrchestrator) do
      system_prompt "route"
      agent delegatable_agent, description: "Does work"
    end

    orch = orch_class.new(message: "work")
    prov = build_provider(
      usage:    { input_tokens: 200, output_tokens: 15 },
      response: "I handled it directly"
    )
    orch.define_singleton_method(:provider_instance) { prov }

    orch.stream { }

    assert_equal 200, orch.last_usage[:input_tokens],
      "orchestrator last_usage must reflect its own call, not any sub-agent's usage"
    assert_equal 15, orch.last_usage[:output_tokens]
  end

  test "orchestrator last_usage is nil before stream — same nil-safe contract as agents" do
    orch = ApplicationOrchestrator.new(message: "test")
    assert_nil orch.last_usage,
      "orchestrator last_usage must return nil gracefully before any stream call"
  end

  # ── 6. last_tool_call_results after multiple tool iterations ─────────────────
  # VERDICT: PASS — @last_tool_call_results is reset to [] at the start of each
  # stream call, then execute_single_tool_call appends on every tool invocation.
  # A loop with 3 iterations (one tool call per turn) produces 3 entries.
  # ALL iterations are recorded, not just the last.
  #
  # Contrast with last_usage: last_usage = receipt from the final turn only.
  # last_tool_call_results = the complete call log for the entire session.
  test "last_tool_call_results accumulates results from ALL tool loop iterations" do
    iter_tool = Class.new(ApplicationTool) do
      tool_name "multi_iteration_tool"
      description "Step"
      def call(**) = "stepped"
    end

    agent_class = Class.new(WritingAgent) { tools iter_tool }
    agent       = agent_class.new(system: "test", message: "go")

    call_count = 0
    agent.define_singleton_method(:provider_instance) do
      call_count += 1
      p = Object.new
      if call_count <= 3
        tc = [{ id: "tc_iter_#{call_count}", name: "multi_iteration_tool", input: {} }]
        p.define_singleton_method(:stream)                 { |_params, &_block| }
        p.define_singleton_method(:last_tool_calls)        { tc }
        p.define_singleton_method(:last_assistant_content) do
          tc.map { |t| { type: "tool_use", id: t[:id], name: t[:name], input: t[:input] } }
        end
      else
        p.define_singleton_method(:stream)                 { |_params, &blk| blk.call("finished") }
        p.define_singleton_method(:last_tool_calls)        { [] }
        p.define_singleton_method(:last_assistant_content) { [] }
      end
      p.define_singleton_method(:last_usage)                  { nil }
      p.define_singleton_method(:format_assistant_turn)       { |c, _| { role: "assistant", content: c } }
      p.define_singleton_method(:format_tool_result_messages) { |r| [{ role: "user", content: r }] }
      p
    end

    agent.stream { }

    assert_equal 3, agent.last_tool_call_results.size,
      "last_tool_call_results must contain one entry per tool invocation — all 3 iterations"

    ids = agent.last_tool_call_results.map { |r| r[:id] }
    assert_equal %w[tc_iter_1 tc_iter_2 tc_iter_3], ids,
      "tool call IDs must appear in iteration order"

    assert agent.last_tool_call_results.all? { |r| r[:result] == "stepped" },
      "every recorded result must be the return value of the tool call"
  end

  test "last_tool_call_results is reset to empty at the start of a new stream call" do
    reset_tool = Class.new(ApplicationTool) do
      tool_name "reset_check_tool"
      description "Check"
      def call(**) = "ran"
    end

    agent_class = Class.new(WritingAgent) { tools reset_tool }
    agent       = agent_class.new(system: "test", message: "go")

    stub_provider(agent, response: "first", tool_calls: [{ id: "tc_r1", name: "reset_check_tool", input: {} }])
    agent.stream { }
    assert_equal 1, agent.last_tool_call_results.size, "first run must record one entry"

    stub_provider(agent, response: "second")
    agent.stream { }
    assert_empty agent.last_tool_call_results,
      "last_tool_call_results must be [] at the start of a new stream — previous results must not leak"
  end
end
