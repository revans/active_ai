require "test_helper"

# Full-stack integration test. Provider is stubbed so no real LLM calls are made.
# Goal: exercise every layer of the stack and find runtime breakage.
class ActiveAIIntegrationTest < ActiveSupport::TestCase

  # ── Agent: complete ────────────────────────────────────────────────────────

  test "agent can be instantiated and build_params returns expected shape" do
    agent = WritingAgent.new(system: "You are a writer.", message: "Write something.")
    params = agent.send(:build_params)

    assert params[:model].present?,       "model must be present"
    assert params[:max_tokens].positive?, "max_tokens must be positive"
    assert_equal "You are a writer.", params[:system]
    assert_kind_of Array, params[:messages]
    assert_equal "Write something.", params[:messages].last[:content]
  end

  test "agent complete returns accumulated text with stubbed stream" do
    klass = Class.new(WritingAgent) do
      define_method(:stream) { |&blk| blk.call("Hello "); blk.call("world") }
    end

    result = klass.new(system: "test", message: "go").complete
    assert_equal "Hello world", result
  end

  test "agent run class method delegates to new.complete" do
    klass = Class.new(WritingAgent) do
      define_method(:stream) { |&blk| blk.call("done") }
      def self.name = "StubbedWritingAgent"
    end

    assert_equal "done", klass.run("go")
  end

  test "agent accepts skills and serializes them into build_params" do
    skill = ToneSkill
    agent = WritingAgent.new(system: "test", message: "hi", skills: [
      Struct.new(:id, :name, :content, keyword_init: true).new(
        id: 1, name: skill.skill_name, content: skill.to_definition[:content]
      )
    ])
    params = agent.send(:build_params)
    assert_equal 1, params[:skills].length
    assert_equal "tone", params[:skills].first[:name]
  end

  test "agent accepts a context and includes it in messages" do
    agent = WritingAgent.new(
      system:   "test",
      context:  "here is the document body",
      message:  "rewrite the intro"
    )
    msgs = agent.send(:build_messages)
    assert_equal "here is the document body", msgs[0][:content]
    assert_equal "assistant",                  msgs[1][:role]
    assert_includes msgs.last[:content], "rewrite the intro"
  end

  # ── Skill: definition ─────────────────────────────────────────────────────

  test "ToneSkill returns a valid definition" do
    defn = ToneSkill.to_definition
    assert_equal "tone", defn[:name]
    assert defn[:content].present?
  end

  test "ToneSkill content does not raise on access" do
    assert_nothing_raised { ToneSkill.content }
  end

  # ── Tool: definition and call ──────────────────────────────────────────────

  test "SearchTool to_definition has correct shape" do
    defn = SearchTool.to_definition
    assert_equal "search",   defn[:name]
    assert_equal "object",   defn.dig(:input_schema, :type)
    assert defn[:description].present?
  end

  test "SearchTool call raises NotImplementedError (expected stub point)" do
    assert_raises(NotImplementedError) { SearchTool.new.call }
  end

  # ── Workflow: structure ───────────────────────────────────────────────────

  test "ResearchWorkflow includes Orchestratable" do
    assert ResearchWorkflow.include?(ActiveAI::Orchestratable)
  end

  test "ResearchWorkflow.run raises NotImplementedError (expected stub point)" do
    assert_raises(NotImplementedError) { ResearchWorkflow.new.run("input") }
  end

  # ── Orchestrator: canonical params ────────────────────────────────────────

  test "EditorialOrchestrator builds canonical params with system prompt" do
    orch   = EditorialOrchestrator.new(message: "coordinate")
    params = orch.to_canonical_params
    assert_equal "You coordinate tasks.",      params[:system]
    assert_equal "coordinate",                 params[:messages].first[:content]
    assert_equal "user",                       params[:messages].first[:role]
    assert_kind_of Array,                      params[:tools]
  end

  test "EditorialOrchestrator uses declared model and provider" do
    assert_equal :anthropic,         EditorialOrchestrator._provider_name
    assert_equal "claude-sonnet-4-6", EditorialOrchestrator._model_config[:name]
    assert_equal 4096,               EditorialOrchestrator._model_config[:max_tokens]
  end

  test "EditorialOrchestrator complete delegates through provider with stub" do
    klass = Class.new(EditorialOrchestrator) do
      define_method(:stream) { |&blk| blk.call("coordinated") }
      def self.name = "StubbedEditorialOrchestrator"
    end

    result = klass.run("do the thing")
    assert_equal "coordinated", result
  end

  # ── Cross-cutting: Orchestratable on agents ───────────────────────────────

  test "WritingAgent includes Orchestratable" do
    assert WritingAgent.include?(ActiveAI::Orchestratable)
  end

  test "WritingAgent.run works with stubbed stream" do
    klass = Class.new(WritingAgent) do
      define_method(:stream) { |&blk| blk.call("result") }
      def self.name = "StubWritingAgent"
    end

    assert_equal "result", klass.run("prompt")
  end
end

class ActiveAIIntegrationTest2 < ActiveSupport::TestCase

  # ── Orchestrator with a real registered agent ──────────────────────────────

  test "can register WritingAgent in orchestrator (requires description)" do
    assert_raises(ArgumentError) do
      Class.new(ApplicationOrchestrator) { agent WritingAgent }
    end
  end

  test "registering WritingAgent with description succeeds and creates meta-tool" do
    WritingAgent.description "Writes content"
    klass = Class.new(ApplicationOrchestrator) do
      system_prompt "coordinate"
      agent WritingAgent, description: "Writes content"
    end
    orch  = klass.new(message: "go")
    names = orch.instance_tools.map(&:tool_name)
    assert_includes names, "writing_agent"
  ensure
    WritingAgent._description = nil
  end

  test "meta-tool for WritingAgent invokes run and returns output" do
    # Subclass with stream stubbed so run doesn't hit the network.
    fast_agent = Class.new(WritingAgent) do
      define_method(:stream) { |&blk| blk.call("written") }
      def self.name = "WritingAgent"
    end

    klass = Class.new(ApplicationOrchestrator) do
      system_prompt "coordinate"
      agent fast_agent, description: "Writes content"
    end

    orch   = klass.new(message: "go")
    tool   = orch.instance_tools.first
    result = tool.call(message: "write this")
    assert_equal "written", result
  end

  # ── Callbacks ─────────────────────────────────────────────────────────────

  test "before_complete and after_complete callbacks fire in order" do
    log = []
    klass = Class.new(WritingAgent) do
      before_complete { log << :before }
      after_complete  { log << :after }
      define_method(:stream) { |&blk| log << :stream; blk.call("x") }
    end
    klass.new(system: "test", message: "go").complete
    assert_equal [:before, :stream, :after], log
  end

  # ── Promptable: missing prompt file ───────────────────────────────────────

  test "prompt() raises when prompt file does not exist" do
    klass = Class.new(WritingAgent) do
      private
      def build_params
        super.merge(system: prompt(:nonexistent))
      end
    end
    agent = klass.new(system: "test", message: "hi")
    assert_raises { agent.send(:build_params) }
  end

  # ── Tool registration in agent ────────────────────────────────────────────

  test "agent with registered tool includes it in canonical params" do
    klass = Class.new(WritingAgent) do
      tools SearchTool
    end
    agent  = klass.new(system: "test", message: "hi")
    params = agent.send(:build_params)
    names  = params[:tools].map { |t| t[:name] }
    assert_includes names, "search"
  end

  # ── Workflow implemented and called ───────────────────────────────────────

  test "implemented workflow run returns result" do
    klass = Class.new(ResearchWorkflow) do
      def run(input) = "researched: #{input}"
    end
    assert_equal "researched: topic", klass.new.run("topic")
  end

  # ── context: lambda on orchestrator ───────────────────────────────────────

  test "context lambda is instance_exec'd and injects context into agent run" do
    ctx_agent = Class.new(ApplicationAgent) do
      def self.name = "CtxAgent"
      def initialize(message:, extra:, **) = @result = "#{extra}|#{message}"
      def complete = @result
      def last_usage = nil
      def last_tool_call_results = []
    end

    klass = Class.new(ApplicationOrchestrator) do
      system_prompt "test"
      agent ctx_agent, description: "needs context",
                       context: -> { { extra: @extra_value } }
    end
    klass.define_method(:initialize) do |message:, extra:|
      super(message: message)
      @extra_value = extra
    end

    orch   = klass.new(message: "go", extra: "injected")
    tool   = orch.instance_tools.first
    result = tool.call(message: "work")
    assert_equal "injected|work", result
  end
end
