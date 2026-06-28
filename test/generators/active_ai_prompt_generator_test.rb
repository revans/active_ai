require "test_helper"
require "rails/generators/test_case"
require "generators/active_ai/prompt/prompt_generator"

# Tests for the active_ai:prompt generator.
#
#   rails generate active_ai:prompt <namespace> <name>
#
# Analogy: think of the generator like a file-sorting machine — it takes a namespace
# and a name, then drops the right stub into exactly the right drawer. These tests
# verify that each drawer receives the right type of paper.
class ActiveAIPromptGeneratorTest < Rails::Generators::TestCase
  tests ActiveAI::Generators::PromptGenerator
  destination File.expand_path("../tmp", __dir__)
  setup :prepare_destination

  # ── File placement ────────────────────────────────────────────────────────────

  test "agent namespace creates file in app/ai/agents/prompts/" do
    run_generator %w[agent writing]
    assert_file "app/ai/agents/prompts/writing.md.erb"
  end

  test "skill namespace creates file in app/ai/skills/prompts/" do
    run_generator %w[skill tone_guidelines]
    assert_file "app/ai/skills/prompts/tone_guidelines.md.erb"
  end

  test "orchestrator namespace creates file in app/ai/orchestrators/prompts/" do
    run_generator %w[orchestrator writing]
    assert_file "app/ai/orchestrators/prompts/writing.md.erb"
  end

  test "workflow namespace creates file in app/ai/workflows/prompts/" do
    run_generator %w[workflow research]
    assert_file "app/ai/workflows/prompts/research.md.erb"
  end

  test "tool namespace creates file in app/ai/tools/prompts/" do
    run_generator %w[tool price_check]
    assert_file "app/ai/tools/prompts/price_check.md.erb"
  end

  test "memory namespace creates file in app/ai/memory/prompts/" do
    run_generator %w[memory embed]
    assert_file "app/ai/memory/prompts/embed.md.erb"
  end

  # ── Template selection ────────────────────────────────────────────────────────

  test "skill uses the static stub — notes that no instance context is available" do
    run_generator %w[skill tone]
    assert_file "app/ai/skills/prompts/tone.md.erb" do |content|
      assert_match "renders without instance context", content,
        "skill stub must warn that @ivars are not available"
    end
  end

  test "agent uses the instance stub — notes that @ivars are available" do
    run_generator %w[agent writing]
    assert_file "app/ai/agents/prompts/writing.md.erb" do |content|
      assert_match "Instance variables", content,
        "agent stub must tell developers @ivars are in scope"
    end
  end

  test "orchestrator uses the instance stub — not the static one" do
    run_generator %w[orchestrator routing]
    assert_file "app/ai/orchestrators/prompts/routing.md.erb" do |content|
      assert_match "Instance variables", content,
        "orchestrator renders with live instance — stub must reflect that"
      refute_match "without instance context", content,
        "orchestrator must not get the skill static stub"
    end
  end

  # ── Name normalization ────────────────────────────────────────────────────────

  test "camel-case name is normalized to snake_case" do
    run_generator %w[agent WritingAssistant]
    assert_file "app/ai/agents/prompts/writing_assistant.md.erb"
  end

  test "hyphenated name is normalized to underscores" do
    run_generator %w[agent writing-assistant]
    assert_file "app/ai/agents/prompts/writing_assistant.md.erb"
  end
end
