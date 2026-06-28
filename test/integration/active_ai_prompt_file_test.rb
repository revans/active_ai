require "test_helper"

# Tests for prompt_file DSL on Skill::Base and Orchestrator.
#
# Skill#prompt_file renders at class load time — no instance exists, so no @ivars.
# Orchestrator#prompt_file renders at call time via _prompt_in_context — the live
# instance is in scope, so @ivars and instance methods are available.
#
# Analogy: skill prompt_file is like a constant defined at boot time (can't reference
# runtime state). Orchestrator prompt_file is like a method body (runs with self in scope).
class ActiveAIPromptFileTest < ActiveSupport::TestCase
  # ── Skill#prompt_file ─────────────────────────────────────────────────────────

  test "skill prompt_file sets _static_content from the prompt file" do
    skill = Class.new(ApplicationSkill) do
      skill_name "file_skill_test_1"
      prompt_file :file_skill_test
    end

    assert_equal "Always write with clarity and precision.", skill._static_content
  end

  test "skill to_definition returns content loaded from prompt file" do
    skill = Class.new(ApplicationSkill) do
      skill_name "file_skill_test_2"
      prompt_file :file_skill_test
    end

    result = skill.to_definition
    assert_equal "file_skill_test_2",                       result[:name]
    assert_equal "Always write with clarity and precision.", result[:content]
  end

  test "skill prompt_file and inline content are mutually exclusive — last one wins" do
    skill = Class.new(ApplicationSkill) do
      skill_name "file_skill_test_3"
      content "Inline content."
      prompt_file :file_skill_test
    end

    assert_equal "Always write with clarity and precision.", skill._static_content,
      "prompt_file called after content must overwrite _static_content"
  end

  test "skill prompt_file raises PromptNotFound for a missing file" do
    assert_raises(ActiveAI::PromptResolver::PromptNotFound) do
      Class.new(ApplicationSkill) do
        skill_name "file_skill_test_4"
        prompt_file :this_file_does_not_exist
      end
    end
  end

  test "skill content error message mentions prompt_file as an option" do
    skill = Class.new(ApplicationSkill) { skill_name "file_skill_test_5" }

    error = assert_raises(NotImplementedError) { skill.content }
    assert_match "prompt_file", error.message,
      "error message must guide developers toward the prompt_file alternative"
  end

  test "skill prompt_file content appears in agent canonical params" do
    skill = Class.new(ApplicationSkill) do
      skill_name "file_skill_test_6"
      prompt_file :file_skill_test
    end

    agent_class = Class.new(WritingAgent) { skills skill }
    params      = agent_class.new(message: "test").to_canonical_params

    skill_entry = params[:skills].find { |s| s[:name] == "file_skill_test_6" }
    refute_nil skill_entry, "file-backed skill must appear in canonical params"
    assert_equal "Always write with clarity and precision.", skill_entry[:content]
  end

  # ── Orchestrator#prompt_file ──────────────────────────────────────────────────

  test "orchestrator prompt_file sets _system_prompt_file on the class" do
    klass = Class.new(ApplicationOrchestrator) do
      provider :anthropic
      model "claude-sonnet-4-6", max_tokens: 512
      prompt_file :static_test
    end

    assert_equal :static_test, klass._system_prompt_file
  end

  test "orchestrator resolved_system_prompt returns plain file content" do
    klass = Class.new(ApplicationOrchestrator) do
      provider :anthropic
      model "claude-sonnet-4-6", max_tokens: 512
      prompt_file :static_test
    end

    orchestrator = klass.new(message: "hello")
    assert_equal "You coordinate writing tasks.", orchestrator.send(:resolved_system_prompt)
  end

  test "orchestrator resolved_system_prompt renders ERB with instance context" do
    klass = Class.new(ApplicationOrchestrator) do
      provider :anthropic
      model "claude-sonnet-4-6", max_tokens: 512
      prompt_file :context_test

      def initialize(message:, role:)
        super(message: message)
        @role = role
      end
    end

    orchestrator = klass.new(message: "hello", role: "coordinator")
    assert_equal "You are a routing agent with role: coordinator.",
                 orchestrator.send(:resolved_system_prompt),
                 "@role must be accessible in the ERB template via _prompt_in_context"
  end

  test "orchestrator resolved_system_prompt falls back to system_prompt DSL when no file is set" do
    klass = Class.new(ApplicationOrchestrator) do
      provider :anthropic
      model "claude-sonnet-4-6", max_tokens: 512
      system_prompt "Inline routing prompt."
    end

    orchestrator = klass.new(message: "hello")
    assert_equal "Inline routing prompt.", orchestrator.send(:resolved_system_prompt)
  end

  test "orchestrator resolved_system_prompt returns empty string when neither DSL nor file is set" do
    klass = Class.new(ApplicationOrchestrator) do
      provider :anthropic
      model "claude-sonnet-4-6", max_tokens: 512
    end

    orchestrator = klass.new(message: "hello")
    assert_equal "", orchestrator.send(:resolved_system_prompt)
  end

  test "orchestrator canonical params system key uses file content" do
    klass = Class.new(ApplicationOrchestrator) do
      provider :anthropic
      model "claude-sonnet-4-6", max_tokens: 512
      prompt_file :static_test
    end

    params = klass.new(message: "hello").to_canonical_params
    assert_equal "You coordinate writing tasks.", params[:system]
  end

  test "orchestrator prompt_file and system_prompt DSL are mutually exclusive — file takes precedence" do
    klass = Class.new(ApplicationOrchestrator) do
      provider :anthropic
      model "claude-sonnet-4-6", max_tokens: 512
      system_prompt "This should be ignored."
      prompt_file :static_test
    end

    orchestrator = klass.new(message: "hello")
    assert_equal "You coordinate writing tasks.", orchestrator.send(:resolved_system_prompt),
      "prompt_file must take precedence over inline system_prompt when both are declared"
  end

  test "orchestrator prompt_file raises PromptNotFound for a missing file" do
    klass = Class.new(ApplicationOrchestrator) do
      provider :anthropic
      model "claude-sonnet-4-6", max_tokens: 512
      prompt_file :this_file_does_not_exist
    end

    assert_raises(ActiveAI::PromptResolver::PromptNotFound) do
      klass.new(message: "hello").send(:resolved_system_prompt)
    end
  end
end
