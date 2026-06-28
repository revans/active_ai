require "test_helper"

# Adversarial integration tests — probing untested paths and edge cases that
# could cause silent failures or confusing runtime errors in real app contexts.
# No real LLM calls are made — tests operate at config, param-build, and
# provider param-construction layers.
class ActiveAIBreakTest < ActiveSupport::TestCase

  # ── Area 1: Credential resolution ─────────────────────────────────────────
  # What happens when api_key_for(:anthropic) is called with no key anywhere?

  test "api_key_for returns nil gracefully when no resolver, credentials, or ENV" do
    original_resolver = ActiveAI.config.api_key_resolver
    original_env      = ENV.delete("ANTHROPIC_API_KEY")
    ActiveAI.config.api_key_resolver = nil

    result = ActiveAI.config.api_key_for(:anthropic)
    assert_nil result, "Expected nil when no key exists — got #{result.inspect}"
  ensure
    ActiveAI.config.api_key_resolver = original_resolver
    ENV["ANTHROPIC_API_KEY"] = original_env if original_env
  end

  test "api_key_for reads from ENV when present" do
    original_resolver = ActiveAI.config.api_key_resolver
    original_env      = ENV["ANTHROPIC_API_KEY"]
    ActiveAI.config.api_key_resolver = nil
    ENV["ANTHROPIC_API_KEY"] = "sk-test-env-key"

    assert_equal "sk-test-env-key", ActiveAI.config.api_key_for(:anthropic)
  ensure
    ActiveAI.config.api_key_resolver = original_resolver
    ENV["ANTHROPIC_API_KEY"] = original_env
  end

  test "api_key_resolver takes priority over ENV" do
    original_resolver = ActiveAI.config.api_key_resolver
    original_env      = ENV["ANTHROPIC_API_KEY"]
    ENV["ANTHROPIC_API_KEY"]          = "sk-from-env"
    ActiveAI.config.api_key_resolver  = ->(_provider) { "sk-from-resolver" }

    assert_equal "sk-from-resolver", ActiveAI.config.api_key_for(:anthropic)
  ensure
    ActiveAI.config.api_key_resolver = original_resolver
    ENV["ANTHROPIC_API_KEY"] = original_env
  end

  test "blank-string resolver falls through to ENV" do
    original_resolver = ActiveAI.config.api_key_resolver
    original_env      = ENV["ANTHROPIC_API_KEY"]
    ENV["ANTHROPIC_API_KEY"]          = "sk-env-fallback"
    ActiveAI.config.api_key_resolver  = ->(_provider) { "" }  # present? is false

    assert_equal "sk-env-fallback", ActiveAI.config.api_key_for(:anthropic)
  ensure
    ActiveAI.config.api_key_resolver = original_resolver
    ENV["ANTHROPIC_API_KEY"] = original_env
  end

  # ── Area 2: Provider instantiation with unknown name ──────────────────────
  # What does provider_class_for return for an unknown provider?

  test "provider_class_for unknown provider raises ConfigurationError with helpful message" do
    error = assert_raises(ActiveAI::ConfigurationError) do
      ActiveAI.provider_class_for(:nonexistent_provider)
    end
    assert_match "nonexistent_provider", error.message
    assert_match "Unknown", error.message
  end

  test "agent with undeclared provider falls back to config provider" do
    # No provider declared → falls back to ActiveAI.config.provider (anthropic by default)
    klass = Class.new(ApplicationAgent)
    agent = klass.new(system: "test", message: "hi")
    assert_equal :anthropic, agent.send(:resolved_provider)
  end

  test "agent with unknown provider name raises ConfigurationError at provider_class resolution" do
    klass = Class.new(ApplicationAgent) do
      provider :definitely_not_real
    end
    agent = klass.new(system: "test", message: "hi")
    error = assert_raises(ActiveAI::ConfigurationError) do
      agent.send(:provider_class)
    end
    assert_match "definitely_not_real", error.message
  end

  # ── Area 3: Cache config shape ─────────────────────────────────────────────
  # Is cacheable always a hash? Can nil slip through and crash the provider?

  test "agent without cache DSL has empty hash for cacheable, not nil" do
    agent  = WritingAgent.new(system: "s", message: "m")
    params = agent.to_canonical_params
    assert_equal({}, params[:cacheable])
    refute_nil params[:cacheable]
  end

  test "orchestrator without cache DSL has empty hash for cacheable, not nil" do
    klass = Class.new(ApplicationOrchestrator) do
      system_prompt "test"
    end
    params = klass.new(message: "test").to_canonical_params
    assert_equal({}, params[:cacheable])
  end

  test "provider build_system_blocks handles nil cacheable without crash" do
    provider  = ActiveAI::Provider::Anthropic.new
    canonical = {
      system:       "system text",
      skills:       [],
      source_files: [],
      messages:     [],
      cacheable:    nil   # explicitly nil — the || {} guard in the provider saves it
    }
    assert_nothing_raised { provider.send(:build_system_blocks, canonical) }
  end

  # ── Area 4: system: nil → empty string → bad Anthropic payload ────────────
  # nil.to_s produces "" which creates an invalid empty text block for Anthropic.

  test "agent with system: nil produces empty string in build_params" do
    agent  = WritingAgent.new(system: nil, message: "test")
    params = agent.to_canonical_params
    assert_equal "", params[:system]
  end

  test "orchestrator with no system_prompt declared produces empty string" do
    klass  = Class.new(ApplicationOrchestrator)
    params = klass.new(message: "test").to_canonical_params
    assert_equal "", params[:system]
  end

  test "provider build_system_blocks with empty system omits the system block" do
    # BUG TARGET: empty text: "" in Anthropic system array is rejected with 400.
    # Fix: skip system block when text is blank.
    provider  = ActiveAI::Provider::Anthropic.new
    canonical = {
      system:       "",
      skills:       [],
      source_files: [],
      messages:     [{ role: "user", content: "hi" }],
      cacheable:    {}
    }
    blocks = provider.send(:build_system_blocks, canonical)
    refute blocks.any? { |b| b[:text].blank? },
      "system block with blank text must not be included — Anthropic API rejects text: \"\""
  end

  test "provider build_system_blocks with non-empty system includes the block" do
    provider  = ActiveAI::Provider::Anthropic.new
    canonical = {
      system:       "You are a writing assistant.",
      skills:       [],
      source_files: [],
      messages:     [],
      cacheable:    {}
    }
    blocks = provider.send(:build_system_blocks, canonical)
    assert blocks.any? { |b| b[:text] == "You are a writing assistant." }
  end

  # ── Area 5: Promptable with real and missing prompt files ──────────────────

  test "prompt() loads real file from app/ai/prompts/ and returns content" do
    prompt_path = Rails.root.join("app", "ai", "prompts", "writing.md")
    FileUtils.mkdir_p(prompt_path.dirname)
    File.write(prompt_path, "You are a skilled writing assistant.")

    klass = Class.new(WritingAgent) do
      private
      def build_params
        super.merge(system: prompt(:writing))
      end
    end

    agent  = klass.new(system: "test", message: "hi")
    params = agent.send(:build_params)
    assert_equal "You are a skilled writing assistant.", params[:system]
  ensure
    File.delete(prompt_path) if prompt_path.exist?
  end

  test "prompt() raises MissingPromptError with file path in message for missing prompt" do
    klass = Class.new(WritingAgent) do
      private
      def build_params
        super.merge(system: prompt(:definitely_nonexistent_xyzzy))
      end
    end

    agent = klass.new(system: "test", message: "hi")
    error = assert_raises(ActiveAI::MissingPromptError) do
      agent.send(:build_params)
    end
    assert_match "definitely_nonexistent_xyzzy", error.message,
      "Error message should name the prompt that was not found"
    assert_match "app/ai/prompts", error.message,
      "Error message should tell the developer where to put the file"
  end

  test "prompt_file() from Promptable reads from app/ai/agents/prompts/ (different namespace)" do
    prompt_path = Rails.root.join("app", "ai", "agents", "prompts", "my_test_agent.md")
    FileUtils.mkdir_p(prompt_path.dirname)
    File.write(prompt_path, "Agent-namespaced prompt content.")

    klass = Class.new(WritingAgent) do
      private
      def build_params
        super.merge(system: prompt_file(:my_test_agent))
      end
    end

    agent  = klass.new(system: "test", message: "hi")
    params = agent.send(:build_params)
    assert_equal "Agent-namespaced prompt content.", params[:system]
  ensure
    File.delete(prompt_path) if prompt_path&.exist?
  end

  test "prompt() and prompt_file() are distinct — same name resolves to different files" do
    prompts_path      = Rails.root.join("app", "ai", "prompts", "shared_name.md")
    agent_prompt_path = Rails.root.join("app", "ai", "agents", "prompts", "shared_name.md")
    FileUtils.mkdir_p(prompts_path.dirname)
    FileUtils.mkdir_p(agent_prompt_path.dirname)
    File.write(prompts_path, "From app/ai/prompts/")
    File.write(agent_prompt_path, "From app/ai/agents/prompts/")

    klass_base = Class.new(WritingAgent) do
      private
      def build_params = super.merge(system: prompt(:shared_name))
    end
    klass_ns = Class.new(WritingAgent) do
      private
      def build_params = super.merge(system: prompt_file(:shared_name))
    end

    base_result = klass_base.new(system: "t", message: "m").send(:build_params)[:system]
    ns_result   = klass_ns.new(system: "t", message: "m").send(:build_params)[:system]

    assert_equal "From app/ai/prompts/",         base_result
    assert_equal "From app/ai/agents/prompts/", ns_result
    refute_equal base_result, ns_result,
      "prompt() and prompt_file() must resolve to different directories"
  ensure
    File.delete(prompts_path)      if prompts_path&.exist?
    File.delete(agent_prompt_path) if agent_prompt_path&.exist?
  end

  # ── Area 6: Tool with no params declared ──────────────────────────────────
  # SearchTool has params commented out — _params is [], parameters is {}.

  test "tool with no params declared produces valid empty input_schema" do
    defn   = SearchTool.to_definition
    schema = defn[:input_schema]
    assert_equal "object", schema[:type]
    assert_equal({},       schema[:properties])
    assert_equal [],       schema[:required]
  end

  test "tool with no params does not raise on to_definition" do
    assert_nothing_raised { SearchTool.to_definition }
  end

  test "tool with no params included in agent produces valid tools array" do
    klass = Class.new(WritingAgent) do
      tools SearchTool
    end
    params     = klass.new(system: "test", message: "hi").to_canonical_params
    search_def = params[:tools].find { |t| t[:name] == "search" }
    refute_nil search_def
    assert_equal({}, search_def.dig(:input_schema, :properties))
    assert_equal [],  search_def.dig(:input_schema, :required)
  end

  # ── Area 7: Orchestrator with no system_prompt declared ───────────────────

  test "orchestrator with no system_prompt builds canonical params without raising" do
    klass = Class.new(ApplicationOrchestrator)
    orch  = klass.new(message: "test")
    assert_nothing_raised { orch.to_canonical_params }
  end

  test "orchestrator with no system_prompt has blank system that will reach provider" do
    klass  = Class.new(ApplicationOrchestrator)
    params = klass.new(message: "test").to_canonical_params
    assert_equal "", params[:system]
    # This blank system string flows to build_system_blocks and creates text: ""
    # which the Anthropic API rejects. The fix in build_system_blocks guards this.
  end

  test "orchestrator build_params does not include nil tools when no tools registered" do
    klass  = Class.new(ApplicationOrchestrator) { system_prompt "test" }
    params = klass.new(message: "test").to_canonical_params
    assert_equal [], params[:tools]
  end

  # ── Area 8: Skill with active content (kwargs) ────────────────────────────

  test "active skill with required kwarg works when context is provided" do
    klass = Class.new(ApplicationSkill) do
      def self.name = "ActiveDocSkill"
      skill_name "active_doc_break"
      def self.content(document:, **)
        "Focusing on: #{document}"
      end
    end

    defn = klass.to_definition(document: "my essay")
    assert_equal "active_doc_break", defn[:name]
    assert_equal "Focusing on: my essay", defn[:content]
  end

  test "active skill with required kwarg raises ArgumentError when context missing" do
    klass = Class.new(ApplicationSkill) do
      def self.name = "ActiveDocSkill2"
      skill_name "active_doc_break_2"
      def self.content(document:, **)
        "Focusing on: #{document}"
      end
    end

    assert_raises(ArgumentError) do
      klass.to_definition   # empty context — :document is required
    end
  end

  test "active skill with optional kwargs works with empty context" do
    klass = Class.new(ApplicationSkill) do
      def self.name = "OptionalDocSkill"
      skill_name "optional_doc_break"
      def self.content(document: nil, **)
        document ? "Focus on: #{document}" : "General guidance."
      end
    end

    defn = klass.to_definition
    assert_equal "General guidance.", defn[:content]
  end

  test "active skill with optional kwargs uses provided context when given" do
    klass = Class.new(ApplicationSkill) do
      def self.name = "OptionalDocSkill2"
      skill_name "optional_doc_break_2"
      def self.content(document: nil, **)
        document ? "Focus on: #{document}" : "General guidance."
      end
    end

    defn = klass.to_definition(document: "the essay")
    assert_equal "Focus on: the essay", defn[:content]
  end

  # ── Bonus: Skill with no content raises NotImplementedError ───────────────

  test "skill subclass with no content declared raises NotImplementedError on to_definition" do
    klass = Class.new(ApplicationSkill) do
      def self.name = "EmptySkill"
      skill_name "empty_skill_break"
      # no content declared
    end

    assert_raises(NotImplementedError) do
      klass.to_definition
    end
  end

  # ── Bonus: tool_name not declared raises NotImplementedError ──────────────

  test "tool with no tool_name raises NotImplementedError on access" do
    klass = Class.new(ApplicationTool) do
      def call(**) = "done"
    end

    assert_raises(NotImplementedError) do
      klass.tool_name
    end
  end

  # ── Bonus: Orchestratable requirement enforced ────────────────────────────

  test "registering agent without Orchestratable raises ArgumentError" do
    bare_agent = Class.new(ActiveAI::Agent::Base) do
      def self.name = "BareAgent"
    end

    assert_raises(ArgumentError) do
      Class.new(ApplicationOrchestrator) do
        system_prompt "test"
        agent bare_agent, description: "does stuff"
      end
    end
  end
end
