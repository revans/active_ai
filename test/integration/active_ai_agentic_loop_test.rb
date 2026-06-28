require "test_helper"

# Adversarial integration tests targeting the agentic tool loop in ActiveAI::Agent::Base.
# All tests stub the provider at the provider_instance level — no real API calls are made.
#
# Tests are written for the target (fixed) behavior. Each section has a VERDICT comment:
#   PASS  — existing code handles it correctly
#   FIX   — a code change was required; see the fix summary in the section comment
class ActiveAIAgenticLoopTest < ActiveSupport::TestCase
  include ActiveAI::TestHelper

  # ── 1. Tool call loop with stubbed stream ────────────────────────────────────
  # VERDICT: PASS — the loop works correctly when the tool is registered and the
  # provider correctly stops requesting tools on the second turn.
  #
  # How stub_provider works: on the first provider_instance call it returns a provider
  # with last_tool_calls populated. On subsequent calls it returns a provider that
  # yields the final text and returns an empty last_tool_calls, breaking the loop.

  test "agentic loop calls registered tool, feeds result back, yields final text" do
    echo_tool = Class.new(ApplicationTool) do
      tool_name "echo_loop_test"
      description "Returns echo"
      def call(**) = "pong"
    end

    agent_class = Class.new(WritingAgent) { tools echo_tool }
    agent = agent_class.new(system: "test", message: "go")
    stub_provider(agent,
      response:   "All done",
      tool_calls: [{ id: "tc_1", name: "echo_loop_test", input: {} }]
    )

    chunks = []
    agent.stream { |e| chunks << e if e.is_a?(String) }

    # (a) tool was called
    assert_ai_tool_called agent, :echo_loop_test

    # (b) result is in last_tool_call_results
    assert_equal "pong", agent.last_tool_call_results.first[:result]

    # (c) final text was yielded to the stream block
    assert_includes chunks, "All done"

    # (d) exactly one tool call recorded
    assert_equal 1, agent.last_tool_call_results.size
  end

  test "stream block receives Hash tool_call event before the final text" do
    ping_tool = Class.new(ApplicationTool) do
      tool_name "ping_loop_test"
      description "Pings"
      def call(**) = "pong"
    end

    agent_class = Class.new(WritingAgent) { tools ping_tool }
    agent = agent_class.new(system: "test", message: "go")
    stub_provider(agent,
      response:   "Final",
      tool_calls: [{ id: "tc_ping", name: "ping_loop_test", input: {} }]
    )

    events = []
    agent.stream { |e| events << e }

    tool_event = events.find { |e| e.is_a?(Hash) && e[:tool_call] }
    refute_nil tool_event, "stream block must receive a Hash { tool_call: } event during tool dispatch"
    assert_equal "tc_ping",       tool_event.dig(:tool_call, :id)
    assert_equal "ping_loop_test", tool_event.dig(:tool_call, :name)
  end

  test "complete accumulates only text chunks — tool_call hashes are not concatenated" do
    noop_tool = Class.new(ApplicationTool) do
      tool_name "noop_complete_test"
      description "No-op"
      def call(**) = "result"
    end

    agent_class = Class.new(WritingAgent) { tools noop_tool }
    agent = agent_class.new(system: "test", message: "go")
    stub_provider(agent,
      response:   "final text",
      tool_calls: [{ id: "tc_noop", name: "noop_complete_test", input: {} }]
    )

    result = agent.complete
    assert_equal "final text", result,
      "complete must return only text chunks, not tool_call event hashes concatenated in"
  end

  # ── 2. Tool raises during execution ──────────────────────────────────────────
  # VERDICT: FIX — without a rescue in execute_single_tool_call, RuntimeError from
  # a tool propagated all the way through the instrument block, the loop, and out
  # of complete, crashing the agent.
  #
  # Fix: a begin/rescue around the tool call in execute_single_tool_call catches
  # all StandardError subclasses and returns "Error: ExceptionClass — message" as
  # the tool_result content. The model sees the error and can decide what to do.

  test "tool raising RuntimeError does not crash complete" do
    boom_tool = Class.new(ApplicationTool) do
      tool_name "boom_test"
      description "Always raises"
      def call(**) = raise RuntimeError, "something broke"
    end

    agent_class = Class.new(WritingAgent) { tools boom_tool }
    agent = agent_class.new(system: "test", message: "go")
    stub_provider(agent,
      response:   "Handled the error",
      tool_calls: [{ id: "tc_boom", name: "boom_test", input: {} }]
    )

    result = nil
    # RuntimeError from a tool must be caught and fed back — not crash complete
    assert_nothing_raised { result = agent.complete }
    assert_equal "Handled the error", result
  end

  test "tool error is recorded in last_tool_call_results with class and message" do
    boom_tool = Class.new(ApplicationTool) do
      tool_name "boom_record_test"
      description "Always raises"
      def call(**) = raise RuntimeError, "kaboom"
    end

    agent_class = Class.new(WritingAgent) { tools boom_tool }
    agent = agent_class.new(system: "test", message: "go")
    stub_provider(agent,
      response:   "ok",
      tool_calls: [{ id: "tc_br", name: "boom_record_test", input: {} }]
    )

    agent.complete

    tool_result = agent.last_tool_call_results.first
    refute_nil tool_result, "last_tool_call_results must contain the failed tool call"
    assert_match "RuntimeError", tool_result[:result],
      "error result must name the exception class so the model knows what happened"
    assert_match "kaboom", tool_result[:result],
      "error result must include the original exception message"
  end

  test "active_ai.tool.call notification result is set even when tool raises" do
    boom_tool = Class.new(ApplicationTool) do
      tool_name "boom_notif_test"
      description "Raises"
      def call(**) = raise ArgumentError, "bad input"
    end

    agent_class = Class.new(WritingAgent) { tools boom_tool }
    agent = agent_class.new(system: "test", message: "go")
    stub_provider(agent,
      response:   "recovered",
      tool_calls: [{ id: "tc_bn", name: "boom_notif_test", input: {} }]
    )

    payloads = []
    sub = ActiveSupport::Notifications.subscribe("tool_call.active_ai") do |_name, _s, _f, _id, payload|
      payloads << payload.dup
    end

    agent.complete

    assert_equal 1, payloads.size
    assert_match "ArgumentError", payloads.first[:result],
      "notification[:result] must still be set when a tool raises"
  ensure
    ActiveSupport::Notifications.unsubscribe(sub) if sub
  end

  # ── 3. Tool result is nil ────────────────────────────────────────────────────
  # VERDICT: PASS — nil.to_s is "" which is valid as Anthropic tool_result content.
  # The tool result stored in last_tool_call_results retains the nil value exactly,
  # while the content fed back to the provider becomes the empty string "".

  test "tool returning nil does not crash — complete finishes normally" do
    nil_tool = Class.new(ApplicationTool) do
      tool_name "nil_returner_test"
      description "Returns nil"
      def call(**) = nil
    end

    agent_class = Class.new(WritingAgent) { tools nil_tool }
    agent = agent_class.new(system: "test", message: "go")
    stub_provider(agent,
      response:   "Completed",
      tool_calls: [{ id: "tc_nil", name: "nil_returner_test", input: {} }]
    )

    assert_nothing_raised { agent.complete }
  end

  test "tool returning nil stores nil in last_tool_call_results" do
    nil_tool = Class.new(ApplicationTool) do
      tool_name "nil_result_check_test"
      description "Returns nil"
      def call(**) = nil
    end

    agent_class = Class.new(WritingAgent) { tools nil_tool }
    agent = agent_class.new(system: "test", message: "go")
    stub_provider(agent,
      response:   "done",
      tool_calls: [{ id: "tc_nr", name: "nil_result_check_test", input: {} }]
    )

    agent.complete
    assert_nil agent.last_tool_call_results.first[:result],
      "nil tool result must be stored as nil, not coerced to a string in last_tool_call_results"
  end

  # ── 4. Infinite tool loop guard ───────────────────────────────────────────────
  # VERDICT: FIX — no iteration limit existed. A provider that always returned
  # tool_calls caused an infinite loop, hanging the process indefinitely.
  #
  # Fix: Base#stream raises ActiveAI::ToolLoopError after MAX_TOOL_ITERATIONS
  # iterations. The limit can be raised per-deployment via the constant.

  test "agentic loop raises ToolLoopError when provider never stops requesting tools" do
    agent = WritingAgent.new(system: "test", message: "go")

    # Stub: every provider_instance always returns a tool call, never breaking the loop.
    agent.define_singleton_method(:provider_instance) do
      prov = Object.new
      prov.define_singleton_method(:stream)                        { |_params, &_block| }
      prov.define_singleton_method(:last_usage)                    { nil }
      prov.define_singleton_method(:last_assistant_content)        { [{ type: "tool_use", id: "tc_inf", name: "loop_tool", input: {} }] }
      prov.define_singleton_method(:last_tool_calls)               { [{ id: "tc_inf", name: "loop_tool", input: {} }] }
      prov.define_singleton_method(:format_assistant_turn)         { |content, _tc| { role: "assistant", content: content } }
      prov.define_singleton_method(:format_tool_result_messages)   { |results| [{ role: "user", content: results }] }
      prov
    end

    assert_raises(ActiveAI::ToolLoopError,
      "infinite tool call loop must raise ToolLoopError — not hang the process") do
      agent.complete
    end
  end

  test "ToolLoopError message names the iteration limit so operators can tune it" do
    agent = WritingAgent.new(system: "test", message: "go")
    agent.define_singleton_method(:provider_instance) do
      prov = Object.new
      prov.define_singleton_method(:stream)                        { |_params, &_block| }
      prov.define_singleton_method(:last_usage)                    { nil }
      prov.define_singleton_method(:last_assistant_content)        { [{ type: "tool_use", id: "tc_lm", name: "x", input: {} }] }
      prov.define_singleton_method(:last_tool_calls)               { [{ id: "tc_lm", name: "x", input: {} }] }
      prov.define_singleton_method(:format_assistant_turn)         { |content, _tc| { role: "assistant", content: content } }
      prov.define_singleton_method(:format_tool_result_messages)   { |results| [{ role: "user", content: results }] }
      prov
    end

    error = assert_raises(ActiveAI::ToolLoopError) { agent.complete }
    assert_match ActiveAI::Agent::Base::MAX_TOOL_ITERATIONS.to_s, error.message,
      "ToolLoopError message must state the limit so operators know what to increase"
  end

  test "legitimate multi-turn tool use within the limit does not raise" do
    # A tool that returns a useful result so the agent resolves after 3 tool calls
    # (well within MAX_TOOL_ITERATIONS). Uses a call counter to drive the stub.
    step_tool = Class.new(ApplicationTool) do
      tool_name "step_tool_test"
      description "Increments"
      def call(**) = "stepped"
    end

    agent_class = Class.new(WritingAgent) { tools step_tool }
    agent = agent_class.new(system: "test", message: "go")

    call_count = 0
    agent.define_singleton_method(:provider_instance) do
      call_count += 1
      prov = Object.new
      if call_count <= 3
        prov.define_singleton_method(:stream)                        { |_params, &_block| }
        prov.define_singleton_method(:last_usage)                    { nil }
        prov.define_singleton_method(:last_assistant_content)        { [{ type: "tool_use", id: "tc_step_#{call_count}", name: "step_tool_test", input: {} }] }
        prov.define_singleton_method(:last_tool_calls)               { [{ id: "tc_step_#{call_count}", name: "step_tool_test", input: {} }] }
      else
        prov.define_singleton_method(:stream)                        { |_params, &block| block.call("finished") }
        prov.define_singleton_method(:last_usage)                    { nil }
        prov.define_singleton_method(:last_assistant_content)        { [] }
        prov.define_singleton_method(:last_tool_calls)               { [] }
      end
      prov.define_singleton_method(:format_assistant_turn)           { |content, _tc| { role: "assistant", content: content } }
      prov.define_singleton_method(:format_tool_result_messages)     { |results| [{ role: "user", content: results }] }
      prov
    end

    result = nil
    # 3 tool call iterations must complete without raising ToolLoopError
    assert_nothing_raised { result = agent.complete }
    assert_equal "finished", result
    assert_equal 3, agent.last_tool_call_results.size
  end

  # ── 5. last_tool_call_results shape ─────────────────────────────────────────
  # VERDICT: PASS — shape is Array<{ id: String, name: String, result: Any }>.
  # Previously undocumented; verified here.

  test "last_tool_call_results has shape Array<{ id:, name:, result: }>" do
    greet_tool = Class.new(ApplicationTool) do
      tool_name "greet_shape_test"
      description "Greets"
      param :name, type: :string, description: "Name to greet"
      def call(name:) = "Hello, #{name}!"
    end

    agent_class = Class.new(WritingAgent) { tools greet_tool }
    agent = agent_class.new(system: "test", message: "go")
    stub_provider(agent,
      response:   "Done",
      tool_calls: [{ id: "tc_shape_1", name: "greet_shape_test", input: { "name" => "world" } }]
    )

    agent.stream { }

    results = agent.last_tool_call_results
    assert_kind_of Array, results

    r = results.first
    assert_kind_of Hash, r
    assert_equal "tc_shape_1",      r[:id],     "id must match the tool_call id from the provider"
    assert_equal "greet_shape_test", r[:name],   "name must match the tool name"
    assert_equal "Hello, world!",   r[:result], "result must be the return value of tool.call"
  end

  test "last_tool_call_results is reset to [] on each new stream call" do
    pong_tool = Class.new(ApplicationTool) do
      tool_name "pong_reset_test"
      description "Returns pong"
      def call(**) = "pong"
    end

    agent_class = Class.new(WritingAgent) { tools pong_tool }
    agent = agent_class.new(system: "test", message: "go")

    stub_provider(agent, response: "first", tool_calls: [{ id: "tc_r1", name: "pong_reset_test", input: {} }])
    agent.stream { }
    assert_equal 1, agent.last_tool_call_results.size, "first run must accumulate one result"

    stub_provider(agent, response: "second")
    agent.stream { }
    assert_empty agent.last_tool_call_results,
      "last_tool_call_results must be reset to [] at the start of each stream call"
  end

  test "last_tool_call_results is accessible via complete" do
    count_tool = Class.new(ApplicationTool) do
      tool_name "count_access_test"
      description "Counts"
      def call(**) = "counted"
    end

    agent_class = Class.new(WritingAgent) { tools count_tool }
    agent = agent_class.new(system: "test", message: "go")
    stub_provider(agent,
      response:   "done",
      tool_calls: [{ id: "tc_ca", name: "count_access_test", input: {} }]
    )

    agent.complete
    assert_equal 1, agent.last_tool_call_results.size,
      "last_tool_call_results must be readable after complete (not just after stream)"
  end

  # ── 6. instance_tools vs _tools in to_canonical_params[:tools] ─────────────
  # VERDICT: FIX — ApplicationAgent#build_params used self.class._tools only,
  # silently excluding instance_tools from canonical params. The model was blind
  # to any tool registered via instance_tools(), making them unreachable.
  #
  # Fix: change build_params to use all_tools.map(&:to_definition) in both the
  # generator template and the testbed ApplicationAgent.

  test "instance_tools appear in to_canonical_params[:tools]" do
    phantom_tool = Class.new(ApplicationTool) do
      tool_name "phantom_instance_test"
      description "Only registered as instance tool"
      def call(**) = "phantom"
    end

    agent_class = Class.new(WritingAgent) do
      define_method(:instance_tools) { [phantom_tool.new] }
    end

    agent      = agent_class.new(system: "test", message: "go")
    params     = agent.to_canonical_params
    tool_names = params[:tools].map { |t| t[:name] }

    assert_includes tool_names, "phantom_instance_test",
      "instance_tools must appear in canonical params so the model knows they exist"
  end

  test "class _tools and instance_tools both appear in canonical params" do
    class_tool = Class.new(ApplicationTool) do
      tool_name "class_level_test"
      description "Class-level tool"
      def call(**) = "class"
    end

    inst_tool = Class.new(ApplicationTool) do
      tool_name "instance_level_test"
      description "Instance-level tool"
      def call(**) = "instance"
    end

    agent_class = Class.new(WritingAgent) do
      tools class_tool
      define_method(:instance_tools) { [inst_tool.new] }
    end

    agent      = agent_class.new(system: "test", message: "go")
    tool_names = agent.to_canonical_params[:tools].map { |t| t[:name] }

    assert_includes tool_names, "class_level_test",    "class-level tool must appear in canonical params"
    assert_includes tool_names, "instance_level_test", "instance-level tool must appear in canonical params"
  end

  test "instance tool is dispatched during the agentic loop" do
    # Proves the full path: instance_tool appears in canonical params → model calls it →
    # execute_single_tool_call finds it via all_tools → result is returned.
    doc_tool = Class.new(ApplicationTool) do
      tool_name "doc_instance_dispatch_test"
      description "Instance tool with document context"
      def initialize(document:) = @document = document
      def call(**) = "doc: #{@document}"
    end

    agent_class = Class.new(WritingAgent) do
      define_method(:instance_tools) { [doc_tool.new(document: "my essay")] }
    end

    agent = agent_class.new(system: "test", message: "go")
    stub_provider(agent,
      response:   "done",
      tool_calls: [{ id: "tc_di", name: "doc_instance_dispatch_test", input: {} }]
    )

    agent.complete

    assert_ai_tool_called agent, :doc_instance_dispatch_test
    assert_equal "doc: my essay", agent.last_tool_call_results.first[:result]
  end

  # ── 7. Duplicate tool names ──────────────────────────────────────────────────
  # VERDICT: FIX — two tools with the same name passed silently through to
  # build_params. Anthropic rejects duplicate names with a 400/422, producing
  # a confusing ProviderError with no indication of the root cause.
  #
  # Fix: Base#stream validates tool names before the first provider call and
  # raises ArgumentError naming the duplicate tool(s).

  test "two class-level tools with the same name raise ArgumentError before the provider is called" do
    tool_a = Class.new(ApplicationTool) do
      tool_name "dupe_name_test"
      description "First"
      def call(**) = "a"
    end
    tool_b = Class.new(ApplicationTool) do
      tool_name "dupe_name_test"
      description "Second"
      def call(**) = "b"
    end

    agent_class = Class.new(WritingAgent) do
      tools tool_a
      tools tool_b
    end

    agent = agent_class.new(system: "test", message: "go")
    assert_raises(ActiveAI::ConfigurationError,
      "duplicate tool names must raise before the API call — not produce a cryptic 400") do
      agent.complete
    end
  end

  test "duplicate tool name error message names the conflicting tool" do
    dup_tool = Class.new(ApplicationTool) do
      tool_name "obviously_duped_test"
      description "Registered twice"
      def call(**) = "x"
    end

    agent_class = Class.new(WritingAgent) do
      tools dup_tool
      tools dup_tool
    end

    agent = agent_class.new(system: "test", message: "go")
    error = assert_raises(ActiveAI::ConfigurationError) { agent.complete }
    assert_match "obviously_duped_test", error.message,
      "error must name the duplicate tool so the developer knows which one to fix"
  end

  test "class tool and instance tool with the same name raise ConfigurationError" do
    shared_name_class = Class.new(ApplicationTool) do
      tool_name "shared_name_conflict_test"
      description "Class version"
      def call(**) = "class"
    end
    shared_name_inst = Class.new(ApplicationTool) do
      tool_name "shared_name_conflict_test"
      description "Instance version"
      def call(**) = "instance"
    end

    agent_class = Class.new(WritingAgent) do
      tools shared_name_class
      define_method(:instance_tools) { [shared_name_inst.new] }
    end

    agent = agent_class.new(system: "test", message: "go")
    assert_raises(ActiveAI::ConfigurationError,
      "class tool and instance tool with the same name must raise ConfigurationError") do
      agent.complete
    end
  end

  # ── 8. Instrumentation events ─────────────────────────────────────────────────
  # active_ai.orchestrator.dispatch fires when a meta-tool dispatches to an agent.
  # active_ai.tool.call fires for each tool invoked in the agentic loop.
  # active_ai.agent.stream fires for the full stream loop (nested inside agent.complete).

  test "orchestrator_dispatch.active_ai notification fires when meta-tool dispatches an agent" do
    fast_agent = Class.new(ApplicationAgent) do
      def self.name = "EchoLoopAgent"
      description "Echoes the message"
      define_method(:stream) { |&blk| blk.call("echoed: #{@message}") }
    end

    orch_class = Class.new(ApplicationOrchestrator) do
      system_prompt "coordinate"
      agent fast_agent, description: "Echoes the message"
    end

    events = []
    sub = ActiveSupport::Notifications.subscribe("orchestrator_dispatch.active_ai") do |_name, _s, _f, _id, payload|
      events << payload.dup
    end

    orch = orch_class.new(message: "go")
    orch.instance_tools.first.call(message: "test input")

    assert_equal 1, events.size, "exactly one orchestrator_dispatch.active_ai must fire per meta-tool call"
    e = events.first
    assert_equal "echo_loop_agent",     e[:step_name]
    assert_equal "test input".length,   e[:input_length]
    assert e[:output_length] > 0,
      "output_length must be set from the agent result length — got #{e[:output_length].inspect}"
  ensure
    ActiveSupport::Notifications.unsubscribe(sub) if sub
  end

  test "tool_call.active_ai notification fires for each tool dispatched in the agentic loop" do
    spy_tool = Class.new(ApplicationTool) do
      tool_name "spy_notification_test"
      description "Notification spy"
      def call(**) = "spied"
    end

    agent_class = Class.new(WritingAgent) { tools spy_tool }
    agent = agent_class.new(system: "test", message: "go")
    stub_provider(agent,
      response:   "done",
      tool_calls: [{ id: "tc_spy", name: "spy_notification_test", input: {} }]
    )

    events = []
    sub = ActiveSupport::Notifications.subscribe("tool_call.active_ai") do |_name, _s, _f, _id, payload|
      events << payload.dup
    end

    agent.complete

    assert_equal 1, events.size, "one tool_call.active_ai notification must fire per tool invocation"
    e = events.first
    assert_equal "spy_notification_test", e[:tool_name]
    assert_equal "spied", e[:result],
      "notification payload must include the return value of the tool call"
  ensure
    ActiveSupport::Notifications.unsubscribe(sub) if sub
  end

  test "agent_stream.active_ai notification payload includes tool_calls from last_tool_call_results" do
    sum_tool = Class.new(ApplicationTool) do
      tool_name "sum_notif_test"
      description "Sums"
      def call(**) = "42"
    end

    agent_class = Class.new(WritingAgent) { tools sum_tool }
    agent = agent_class.new(system: "test", message: "go")
    stub_provider(agent,
      response:   "sum is 42",
      tool_calls: [{ id: "tc_sn", name: "sum_notif_test", input: {} }]
    )

    stream_events = []
    sub = ActiveSupport::Notifications.subscribe("agent_stream.active_ai") do |_name, _s, _f, _id, payload|
      stream_events << payload.dup
    end

    agent.complete

    assert_equal 1, stream_events.size
    tool_call_results = stream_events.first[:tool_calls]
    assert_kind_of Array, tool_call_results
    assert_equal 1, tool_call_results.size
    assert_equal "sum_notif_test", tool_call_results.first[:name]
  ensure
    ActiveSupport::Notifications.unsubscribe(sub) if sub
  end
end
