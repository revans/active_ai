require "test_helper"

# Adversarial edge-case integration tests — 13 attack vectors targeting provider
# routing, DSL semantics, orchestrator wiring, and tool-level LLM calls.
# No real API calls — every provider interaction is stubbed at the
# provider_instance level.
#
# VERDICT comments mark each section:
#   PASS  — existing code handles it correctly
#   FIX   — a code change was applied; see in-line fix note
class ActiveAIEdgeCasesTest < ActiveSupport::TestCase
  include ActiveAI::TestHelper

  # ── 1. Provider instance caching ─────────────────────────────────────────────
  # provider_instance calls provider_class.new every time — it is NOT memoized.
  # Calling complete twice on the same agent instance must produce two independent
  # providers. Accumulated state (e.g. last_tool_calls from turn 1) must not bleed
  # into turn 2 because stream() resets @last_tool_call_results = [] at entry.
  #
  # VERDICT: PASS — no memoization exists; @last_tool_call_results resets on entry.

  test "second complete call on same instance does not reuse first provider instance" do
    agent = WritingAgent.new(system: "test", message: "go")

    provider_call_count = 0
    agent.define_singleton_method(:provider_instance) do
      provider_call_count += 1
      prov = Object.new
      prov.define_singleton_method(:stream)                       { |_params, &block| block.call("r#{provider_call_count}") }
      prov.define_singleton_method(:last_usage)                   { nil }
      prov.define_singleton_method(:last_tool_calls)              { [] }
      prov.define_singleton_method(:last_assistant_content)       { [] }
      prov.define_singleton_method(:format_assistant_turn)        { |c, _tc| { role: "assistant", content: c } }
      prov.define_singleton_method(:format_tool_result_messages)  { |r| [{ role: "user", content: r }] }
      prov
    end

    result1 = agent.complete
    result2 = agent.complete

    assert_equal 2, provider_call_count,
      "provider_instance must be called once per complete invocation, not shared"
    assert_equal "r1", result1
    assert_equal "r2", result2,
      "second complete must use a fresh provider — accumulated state must not carry over"
  end

  test "last_tool_call_results resets between complete calls even with prior tool state" do
    ping_tool = Class.new(ApplicationTool) do
      tool_name "ping_ec_test"
      description "Ping"
      def call(**) = "pong"
    end
    agent_class = Class.new(WritingAgent) { tools ping_tool }
    agent = agent_class.new(system: "test", message: "go")

    # First call: one tool invocation
    stub_provider(agent,
      response: "first", tool_calls: [{ id: "tc1", name: "ping_ec_test", input: {} }])
    agent.complete
    assert_equal 1, agent.last_tool_call_results.size

    # Second call: no tool invocations
    stub_provider(agent, response: "second")
    agent.complete
    assert_empty agent.last_tool_call_results,
      "last_tool_call_results must be reset to [] at the start of the second complete call"
  end

  # ── 2. Runtime provider override ─────────────────────────────────────────────
  # Agent class declares provider :anthropic. Instance is created with provider: :openai.
  # resolved_provider must return :openai; provider_class must be the OpenAI class.
  #
  # VERDICT: PASS — @runtime_provider takes priority in resolved_provider.

  test "runtime provider: kwarg overrides class-level provider declaration in resolved_provider" do
    klass = Class.new(ApplicationAgent) do
      provider :anthropic
    end

    agent = klass.new(system: "s", message: "m", provider: :openai)
    assert_equal :openai, agent.resolved_provider,
      "runtime provider: kwarg must override the class-level provider declaration"
  end

  test "runtime provider: kwarg causes correct provider class to be instantiated" do
    klass = Class.new(ApplicationAgent) do
      provider :anthropic
    end

    agent = klass.new(system: "s", message: "m", provider: :openai)
    assert_equal ActiveAI::Provider::OpenAI, agent.send(:provider_class),
      "provider_class must resolve to OpenAI when runtime provider: :openai is passed"
  end

  # ── 3. Runtime model override ─────────────────────────────────────────────────
  # Agent class declares a specific model. Instance is created with model: "gpt-4o".
  # resolved_model must return "gpt-4o", and build_params[:model] must reflect it.
  #
  # VERDICT: PASS — @runtime_model is checked first in ApplicationAgent#resolved_model.

  test "runtime model: kwarg overrides class-level model declaration in build_params" do
    klass = Class.new(ApplicationAgent) do
      provider :anthropic
      model "claude-opus-4-8", max_tokens: 4096
    end

    agent = klass.new(system: "s", message: "m", model: "gpt-4o")
    params = agent.to_canonical_params

    assert_equal "gpt-4o", params[:model],
      "runtime model: kwarg must appear in build_params[:model], overriding the class-level model"
  end

  test "runtime model: kwarg is returned by resolved_model" do
    klass = Class.new(ApplicationAgent) do
      provider :anthropic
      model "claude-opus-4-8"
    end

    agent = klass.new(system: "s", message: "m", model: "override-model")
    assert_equal "override-model", agent.resolved_model,
      "resolved_model must return the runtime model kwarg when present"
  end

  # ── 4. Tool that calls an LLM ─────────────────────────────────────────────────
  # Tool::Base#complete(input) calls provider_instance.call(canonical_params)
  # and returns the string result. Tests that the full round-trip works when
  # the tool's own provider/model/system config is correctly set up.
  #
  # VERDICT: PASS — Tool#complete calls provider_instance.call with a well-formed
  # canonical payload. The provider's call method returns a string directly.

  test "Tool::Base complete calls provider_instance.call with a canonical payload" do
    summary_tool = Class.new(ApplicationTool) do
      tool_name "ec_summarize_test"
      description "Summarizes text"
      provider :anthropic
      model "claude-haiku-4-5-20251001", max_tokens: 256
      system_prompt "Return a one-sentence summary."
      param :text, type: :string, description: "Text to summarize"

      def call(text:)
        complete(text)
      end
    end

    received_canonical = nil
    tool_instance = summary_tool.new
    tool_instance.define_singleton_method(:provider_instance) do
      prov = Object.new
      prov.define_singleton_method(:call) do |canonical|
        received_canonical = canonical
        "A short summary."
      end
      prov
    end

    result = tool_instance.call(text: "Long article text here.")

    assert_equal "A short summary.", result,
      "Tool#complete must return the string from provider_instance.call"
    refute_nil received_canonical,
      "provider_instance.call must be invoked with a canonical params hash"
    assert_equal "claude-haiku-4-5-20251001", received_canonical[:model],
      "canonical params must include the tool's own model"
    assert_equal "Return a one-sentence summary.", received_canonical[:system],
      "canonical params must include the tool's own system_prompt"
    assert_equal [{ role: "user", content: "Long article text here." }],
      received_canonical[:messages],
      "canonical messages must contain the input as a user message"
  end

  test "Tool::Base complete uses the tool's own provider config, not the calling agent's" do
    xai_tool = Class.new(ApplicationTool) do
      tool_name "ec_xai_tool_test"
      description "XAI tool"
      provider :xai
      model "grok-3", max_tokens: 128
      system_prompt "Be brief."
      param :query, type: :string, description: "Query"

      def call(query:)
        complete(query)
      end
    end

    resolved_provider_sym = nil
    tool_instance = xai_tool.new
    tool_instance.define_singleton_method(:provider_instance) do
      resolved_provider_sym = self.send(:resolved_provider)
      prov = Object.new
      prov.define_singleton_method(:call) { |_p| "xai result" }
      prov
    end

    tool_instance.call(query: "hello")

    assert_equal :xai, resolved_provider_sym,
      "Tool#complete must use the tool's own provider declaration (xai), not the global default"
  end

  # ── 5. all_tools with zero tools ─────────────────────────────────────────────
  # Agent with no tools DSL and default instance_tools returns []. Both all_tools
  # and to_canonical_params[:tools] must return [] — not nil or raise.
  #
  # VERDICT: PASS — _tools defaults to [], instance_tools defaults to [].

  test "all_tools returns [] when agent has no tools DSL and default instance_tools" do
    klass = Class.new(ApplicationAgent)  # no tools declared
    agent = klass.new(system: "s", message: "m")
    assert_equal [], agent.all_tools,
      "all_tools must return [] when neither class tools nor instance_tools are declared"
  end

  test "to_canonical_params[:tools] is [] not nil for a tool-less agent" do
    klass  = Class.new(ApplicationAgent)
    params = klass.new(system: "s", message: "m").to_canonical_params
    assert_equal [], params[:tools],
      "canonical params :tools must be [] not nil — providers expect an array"
  end

  test "provider receives empty tools array, not nil, for a tool-less agent" do
    klass = Class.new(ApplicationAgent)
    agent = klass.new(system: "s", message: "m")

    received_tools = :not_called
    agent.define_singleton_method(:provider_instance) do
      prov = Object.new
      prov.define_singleton_method(:stream) do |params, &block|
        received_tools = params[:tools]
        block.call("done")
      end
      prov.define_singleton_method(:last_usage)                   { nil }
      prov.define_singleton_method(:last_tool_calls)              { [] }
      prov.define_singleton_method(:last_assistant_content)       { [] }
      prov.define_singleton_method(:format_assistant_turn)        { |c, _tc| { role: "assistant", content: c } }
      prov.define_singleton_method(:format_tool_result_messages)  { |r| [{ role: "user", content: r }] }
      prov
    end

    agent.complete

    assert_equal [], received_tools,
      "provider#stream must receive tools: [] not nil for a tool-less agent"
  end

  # ── 6. Orchestrator context_for with unexpected kwargs ───────────────────────
  # context_for returns a key that ApplicationAgent#initialize does not accept.
  # klass.run(message, **ctx) becomes new(message:, unknown_kwarg:).complete and
  # raises ArgumentError: unknown keyword. The orchestrator does not rescue this.
  #
  # VERDICT: BUG — the error is an opaque ArgumentError with no mention of which
  # orchestrator or which context key caused it. Document current behavior.
  # No code fix applied here — the caller owns their context_for contract.
  # A future improvement would wrap this with a clearer ConfigurationError.

  test "orchestrator context_for returning unknown kwargs crashes agent.run with ArgumentError" do
    small_agent = Class.new(ApplicationAgent) do
      def self.name = "SmallContextAgent"
      description "Minimal agent"
      # initialize accepts: system, context, source_files, history, skills,
      # focus, message, file_name, file_content, provider, model — NOT unknown_kwarg
    end

    orch_class = Class.new(ApplicationOrchestrator) do
      system_prompt "coordinate"
      agent small_agent, description: "Minimal agent"

      def context_for(klass)
        { project: "my_project", unknown_kwarg: "boom" }
      end
    end

    orch = orch_class.new(message: "go")
    meta_tool = orch.instance_tools.first

    assert_raises(ArgumentError,
      "context_for returning unknown kwargs must crash with ArgumentError — " \
      "the orchestrator does not protect against mismatched context keys") do
      meta_tool.call(message: "do something")
    end
  end

  # ── 7. Orchestrator with no registered agents or workflows ────────────────────
  # An orchestrator with zero meta-tools must not raise on to_canonical_params.
  # tools: must be [] not nil. to_canonical_params must succeed.
  #
  # VERDICT: PASS — all_tools returns [] when _meta_tool_factories and _tools are empty.

  test "orchestrator with no registered agents or workflows returns tools: [] in canonical params" do
    klass  = Class.new(ApplicationOrchestrator) { system_prompt "nothing here" }
    params = klass.new(message: "test").to_canonical_params

    assert_equal [], params[:tools],
      "to_canonical_params[:tools] must be [] when no agents/workflows/tools are registered"
  end

  test "orchestrator with zero tools does not raise on to_canonical_params" do
    klass = Class.new(ApplicationOrchestrator)
    assert_nothing_raised { klass.new(message: "test").to_canonical_params }
  end

  # ── 8. Orchestrator run class method ─────────────────────────────────────────
  # Orchestrator.run("input") must delegate to new(message: "input").complete,
  # which runs the full agentic loop (provider call → tool dispatch → final text).
  # It does not skip to a direct stream; it uses Base#complete.
  #
  # VERDICT: PASS — Base.run calls new(message: input).complete; Orchestrator
  # inherits this. The agentic loop fires through Base#stream as normal.

  test "Orchestrator.run delegates through new(message:).complete and the full agentic loop" do
    # Use a subclass so we can inject a stubbed provider via define_method
    # (define_method at the class level affects all instances of that class).
    test_orch_class = Class.new(ApplicationOrchestrator) do
      system_prompt "orchestrate"

      define_method(:provider_instance) do
        prov = Object.new
        prov.define_singleton_method(:stream)                      { |_p, &block| block.call("orchestrated") }
        prov.define_singleton_method(:last_usage)                  { nil }
        prov.define_singleton_method(:last_tool_calls)             { [] }
        prov.define_singleton_method(:last_assistant_content)      { [] }
        prov.define_singleton_method(:format_assistant_turn)       { |c, _tc| { role: "assistant", content: c } }
        prov.define_singleton_method(:format_tool_result_messages) { |r| [{ role: "user", content: r }] }
        prov
      end
    end

    result = test_orch_class.run("go")

    assert_equal "orchestrated", result,
      "Orchestrator.run must route through new.complete and the full agentic loop"
  end

  test "Orchestrator.run can dispatch a registered tool through the loop" do
    count_tool = Class.new(ApplicationTool) do
      tool_name "ec_orch_count_test"
      description "Counts"
      def call(**) = "42"
    end

    test_orch_class = Class.new(ApplicationOrchestrator) do
      system_prompt "count things"
      tools count_tool
    end

    orch_instance_for_stub = nil
    test_orch_class.define_method(:initialize) do |message:|
      super(message: message)
      orch_instance_for_stub = self
    end

    # Capture the instance so we can stub the provider on it via run
    # We must stub after the instance is created — intercept at initialize time
    original_provider_instance = nil
    test_orch_class.define_method(:provider_instance) do
      call_n = (instance_variable_get(:@_ec_call_n) || 0) + 1
      instance_variable_set(:@_ec_call_n, call_n)
      prov = Object.new
      if call_n == 1
        prov.define_singleton_method(:stream)                      { |_p, &block| }
        prov.define_singleton_method(:last_usage)                  { nil }
        prov.define_singleton_method(:last_tool_calls)             { [{ id: "tc_oc", name: "ec_orch_count_test", input: {} }] }
        prov.define_singleton_method(:last_assistant_content)      { [{ type: "tool_use", id: "tc_oc", name: "ec_orch_count_test", input: {} }] }
      else
        prov.define_singleton_method(:stream)                      { |_p, &block| block.call("result: 42") }
        prov.define_singleton_method(:last_usage)                  { nil }
        prov.define_singleton_method(:last_tool_calls)             { [] }
        prov.define_singleton_method(:last_assistant_content)      { [] }
      end
      prov.define_singleton_method(:format_assistant_turn)         { |c, _tc| { role: "assistant", content: c } }
      prov.define_singleton_method(:format_tool_result_messages)   { |r| [{ role: "user", content: r }] }
      prov
    end

    result = test_orch_class.run("count something")
    assert_equal "result: 42", result,
      "Orchestrator.run must execute the full tool-call loop, not short-circuit"
  end

  # ── 9. Workflow run via orchestrator meta-tool ────────────────────────────────
  # When a workflow is registered in an orchestrator, the meta-tool calls
  # WorkflowClass.run(message, **ctx), which calls new.run(input). The string
  # return value must flow back through the meta-tool call.
  #
  # VERDICT: PASS — Workflow.run delegates to new.run, result flows through
  # instrument_step and is returned by meta_tool.call.

  test "workflow registered in orchestrator meta-tool routes to workflow.run and returns string result" do
    stub_workflow = Class.new(ApplicationWorkflow) do
      def self.name = "StubResearchWorkflow"
      description "Stub research"

      def run(input)
        "workflow processed: #{input}"
      end
    end

    orch_class = Class.new(ApplicationOrchestrator) do
      system_prompt "coordinate"
      workflow stub_workflow, description: "Stub research"
    end

    orch     = orch_class.new(message: "go")
    meta_tool = orch.instance_tools.first

    result = meta_tool.call(message: "research this topic")

    assert_equal "workflow processed: research this topic", result,
      "workflow meta-tool must call workflow.run(input) and return the string result"
  end

  test "workflow meta-tool fires step.active_ai notification with output_length" do
    stub_wf = Class.new(ApplicationWorkflow) do
      def self.name = "StepNotifWorkflow"
      description "Notif test"

      def run(input)
        "done: #{input}"
      end
    end

    orch_class = Class.new(ApplicationOrchestrator) do
      system_prompt "coordinate"
      workflow stub_wf, description: "Notif test"
    end

    orch      = orch_class.new(message: "go")
    meta_tool = orch.instance_tools.first

    events = []
    sub = ActiveSupport::Notifications.subscribe("step.active_ai") do |_n, _s, _f, _id, payload|
      events << payload.dup
    end

    meta_tool.call(message: "topic")

    assert_equal 1, events.size, "exactly one step.active_ai must fire per workflow meta-tool call"
    assert events.first[:output_length] > 0,
      "output_length in the notification must reflect the workflow result length"
  ensure
    ActiveSupport::Notifications.unsubscribe(sub) if sub
  end

  # ── 10. skill_name DSL called twice ──────────────────────────────────────────
  # Calling skill_name twice on a class: last call wins (class_attribute semantics).
  # The registry must not duplicate the class — it maps by class name so the
  # second call overwrites the first entry.
  #
  # VERDICT: PASS — class_attribute is a simple setter; second call overwrites first.

  test "skill_name DSL called twice — last value wins" do
    klass = Class.new(ApplicationSkill) do
      def self.name = "TwiceNamedSkill"
      skill_name "first_name"
      skill_name "second_name"
      content "skill content"
    end

    assert_equal "second_name", klass.skill_name,
      "calling skill_name twice must have the last call win"
  end

  test "skill_name called twice — class appears once in registry under last name" do
    klass = Class.new(ApplicationSkill) do
      def self.name = "TwiceRegisteredSkill"
      skill_name "alpha_name"
      skill_name "beta_name"
      content "content"
    end

    registered_count = ActiveAI.skills.count { |k| k == klass }
    assert_equal 1, registered_count,
      "class must appear exactly once in the registry regardless of how many times skill_name is called"

    # The registry key is the class name — only the class object is stored,
    # not the skill_name string. Verify the class is findable.
    assert ActiveAI.registry.key?("TwiceRegisteredSkill"),
      "registry must key by class name, not by skill_name string"
  end

  # ── 11. tool_name DSL with complete ──────────────────────────────────────────
  # A tool class can declare both the identity DSL (tool_name, description) and
  # the LLM-calling DSL (provider, model, system_prompt, complete). These are
  # independent class_attributes on Tool::Base.
  #
  # VERDICT: PASS — no conflict; tool_name sets _tool_name, complete uses
  # _provider_name / _model_config / _system_prompt independently.

  test "tool_name DSL coexists with provider/model/system_prompt DSL on same tool class" do
    llm_tool = Class.new(ApplicationTool) do
      tool_name "ec_llm_ident_test"
      description "LLM-calling tool"
      provider :anthropic
      model "claude-haiku-4-5-20251001", max_tokens: 128
      system_prompt "Be concise."
      param :input, type: :string, description: "Input text"

      def call(input:)
        complete(input)
      end
    end

    assert_equal "ec_llm_ident_test", llm_tool.tool_name,
      "tool_name must be accessible after declaring provider/model/system_prompt"
    assert_equal :anthropic, llm_tool._provider_name,
      "_provider_name must be stored independently of tool_name"
    assert_equal "claude-haiku-4-5-20251001", llm_tool._model_config[:name],
      "_model_config must be stored independently of tool_name"
    assert_equal "Be concise.", llm_tool._system_prompt,
      "_system_prompt must be stored independently of tool_name"

    # to_definition must still produce a valid tool definition
    defn = llm_tool.to_definition
    assert_equal "ec_llm_ident_test", defn[:name]
    assert_equal "LLM-calling tool",  defn[:description]
  end

  test "tool with complete delegates to provider_instance.call not stream" do
    # complete() calls provider_instance.call, not stream — verifies the contract.
    call_invoked   = false
    stream_invoked = false

    llm_tool = Class.new(ApplicationTool) do
      tool_name "ec_call_vs_stream_test"
      description "Tests complete uses call not stream"
      provider :anthropic
      model "claude-haiku-4-5-20251001", max_tokens: 128
      system_prompt "Return yes."
      param :q, type: :string, description: "Question"

      def call(q:)
        complete(q)
      end
    end

    tool_instance = llm_tool.new
    tool_instance.define_singleton_method(:provider_instance) do
      prov = Object.new
      prov.define_singleton_method(:call) { |_p| call_invoked = true; "yes" }
      prov.define_singleton_method(:stream) { |_p, &_b| stream_invoked = true }
      prov
    end

    tool_instance.call(q: "yes or no?")

    assert call_invoked,   "Tool#complete must call provider_instance.call (blocking)"
    refute stream_invoked, "Tool#complete must NOT call provider_instance.stream"
  end

  # ── 12. description DSL on an anonymous class ─────────────────────────────────
  # description() calls ActiveAI.register(self) only when name.present? is true.
  # Anonymous classes have name == nil, so they are not registered globally.
  # The _description value is stored via class_attribute on the anonymous class,
  # NOT on the parent class, so it cannot leak upward.
  #
  # VERDICT: PASS — name.present? guard prevents registration; class_attribute
  # creates per-class storage that does not leak to the parent.

  test "description DSL on anonymous class stores on the anon class" do
    anon = Class.new(ApplicationAgent) { description "anonymous description" }

    assert_equal "anonymous description", anon._description,
      "description must be stored on the anonymous class"
  end

  test "description DSL on anonymous class does not leak to ApplicationAgent" do
    # ApplicationAgent does not declare a description — it must stay nil
    # even after a subclass (anonymous) calls description().
    _anon = Class.new(ApplicationAgent) { description "should not leak" }

    assert_nil ApplicationAgent._description,
      "ApplicationAgent._description must remain nil — subclass description() must not leak to parent"
  end

  test "description on anonymous class does not register it in ActiveAI.registry" do
    count_before = ActiveAI.registry.size
    _anon = Class.new(ApplicationAgent) { description "ghost" }
    count_after = ActiveAI.registry.size

    assert_equal count_before, count_after,
      "anonymous class (name == nil) must not be added to ActiveAI.registry"
  end

  # ── 13. param DSL with duplicate param names ──────────────────────────────────
  # The param DSL appends to _params without checking for duplicates.
  # Declaring the same param name twice produces a duplicate in the required
  # array, which is incorrect — Anthropic API rejects duplicate required entries.
  #
  # VERDICT: FIX — to_definition was modified to deduplicate the required array.
  # Before fix: required was ["query", "query"].
  # After fix: required is ["query"].

  test "param DSL declared twice on same name accumulates entries in _params" do
    klass = Class.new(ApplicationTool) do
      tool_name "ec_dup_param_test"
      description "Dup param tool"
      param :query, type: :string, description: "First query"
      param :query, type: :string, description: "Second query (duplicate)"
    end

    assert_equal 2, klass._params.size,
      "_params accumulates both entries — no deduplication at declaration time"
  end

  test "param DSL declared twice — parameters hash has only one entry (last wins via hash overwrite)" do
    klass = Class.new(ApplicationTool) do
      tool_name "ec_dup_param_props_test"
      description "Dup params"
      param :query, type: :string, description: "First"
      param :query, type: :string, description: "Second"
    end

    props = klass.parameters
    assert_equal 1, props.size,
      "parameters hash must have one entry for :query — second overwrites first"
    assert_equal "Second", props[:query][:description]
  end

  test "param DSL declared twice — required array must not contain duplicates after fix" do
    klass = Class.new(ApplicationTool) do
      tool_name "ec_dup_required_test"
      description "Dup required"
      param :query, type: :string, description: "First"
      param :query, type: :string, description: "Second"
    end

    required = klass.to_definition.dig(:input_schema, :required)

    assert_equal ["query"], required,
      "required array must deduplicate entries — [\"query\", \"query\"] is invalid " \
      "and causes Anthropic API 422 errors. Fix: deduplicate in to_definition."
  end
end
