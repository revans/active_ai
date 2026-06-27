require "test_helper"

# Adversarial integration tests for the active skill (kwargs) path and skill DSL mechanics.
# Tests that read build_params do not make real API calls.
# Tests that exercise the stream path use the stub_provider helper.
#
# VERDICT key:
#   PASS   — existing code handles it correctly; test documents the behavior
#   FIX    — a code change was required; see section comment for details
class ActiveAIActiveSkillTest < ActiveSupport::TestCase
  include ActiveAI::TestHelper

  # ── 7. Active skill to_definition with context ───────────────────────────────
  # VERDICT: PASS — Skill::Base.to_definition inspects method(:content).parameters.
  # When kwargs are present (:key, :keyreq, :keyrest types), it calls content(**context).
  # Passive skills (no kwargs) get content() with no args — backwards compatible.
  #
  # Analogy: to_definition is a method-signature detector — it reads the formal
  # parameter list and decides whether to pass arguments or call bare.
  test "active skill to_definition with context kwarg returns the dynamically resolved content" do
    citation_skill = Class.new(ApplicationSkill) do
      skill_name "citation_test_7a"
      def self.content(document: nil, **)
        document ? "Cite sources relevant to: #{document}" : "Cite general sources."
      end
    end

    result = citation_skill.to_definition(document: "War and Peace excerpt")

    assert_equal "citation_test_7a", result[:name]
    assert_equal "Cite sources relevant to: War and Peace excerpt", result[:content],
      "context kwarg must be forwarded to content() and produce the dynamic result"
  end

  test "active skill to_definition with empty context falls back to default kwarg value" do
    fallback_skill = Class.new(ApplicationSkill) do
      skill_name "fallback_active_test_7b"
      def self.content(document: nil, **)
        document ? "Document: #{document}" : "No document provided."
      end
    end

    result = fallback_skill.to_definition({})
    assert_equal "No document provided.", result[:content],
      "empty context must trigger the default kwarg value, not raise ArgumentError"
  end

  test "passive skill to_definition ignores any context passed and returns static content" do
    static_skill = Class.new(ApplicationSkill) do
      skill_name "static_passive_test_7c"
      content "Always write in a direct tone."
    end

    result_no_ctx   = static_skill.to_definition
    result_with_ctx = static_skill.to_definition(document: "something", irrelevant: true)

    assert_equal "Always write in a direct tone.", result_no_ctx[:content]
    assert_equal result_no_ctx[:content], result_with_ctx[:content],
      "passive skill content must be identical regardless of what context is passed"
  end

  # ── 8. Active skill in build_params[:skills] via class-level DSL ─────────────
  # VERDICT: FIX — ApplicationAgent#build_params previously mapped only @skills
  # (runtime-passed AR model objects). The class-level `skills` DSL writes to
  # self.class._skills, but build_params never read it — class-level skills were
  # silently swallowed.
  #
  # The Orchestrator correctly reads self.class._skills.
  # ApplicationAgent was behind. writer-v3's ApplicationAgent already had the fix.
  # Fixed by updating build_params in:
  #   active_ai_testbed/app/ai/agents/application_agent.rb
  #   gems/active_ai/lib/generators/active_ai/install/templates/application_agent.rb
  test "class-level passive skill declared via DSL appears in build_params — not silently dropped" do
    passive_skill = Class.new(ApplicationSkill) do
      skill_name "dsl_passive_skill_test_8a"
      content "Write clearly and concisely."
    end

    agent_class = Class.new(WritingAgent) { skills passive_skill }
    agent       = agent_class.new(message: "test")
    params      = agent.to_canonical_params

    skill_names  = params[:skills].map { |s| s[:name] }
    skill_bodies = params[:skills].map { |s| s[:content] }

    assert_includes skill_names,  "dsl_passive_skill_test_8a",
      "class-level skill must appear in canonical params — it was being silently dropped before the fix"
    assert_includes skill_bodies, "Write clearly and concisely.",
      "skill content must be present in the canonical params sent to the provider"
  end

  test "class-level active skill appears in build_params with content resolved from skill_context" do
    active_skill = Class.new(ApplicationSkill) do
      skill_name "dsl_active_skill_test_8b"
      def self.content(message: nil, **)
        message ? "Write about: #{message}" : "Write about anything."
      end
    end

    agent_class = Class.new(WritingAgent) { skills active_skill }
    # skill_context = { message: "the ocean", context: nil } is passed to to_definition
    agent       = agent_class.new(message: "the ocean")
    skill_bodies = agent.to_canonical_params[:skills].map { |s| s[:content] }

    assert_includes skill_bodies, "Write about: the ocean",
      "active skill must receive skill_context so the content reflects the runtime message"
  end

  test "class-level skill appears in the provider's system blocks when the agent streams" do
    style_skill = Class.new(ApplicationSkill) do
      skill_name "stream_dsl_skill_test_8c"
      content "Use formal language."
    end

    agent_class = Class.new(WritingAgent) { skills style_skill }
    agent       = agent_class.new(message: "test")
    stub_provider(agent, response: "done")

    # The stream must not raise. The canonical params include the skill content
    # which the Anthropic provider uses to build system blocks.
    agent.stream { }

    skill_block = agent.to_canonical_params[:skills].find { |s| s[:name] == "stream_dsl_skill_test_8c" }
    refute_nil   skill_block,             "class-level skill must appear in canonical params"
    assert_equal "Use formal language.", skill_block[:content]
  end

  # ── 9. Class-level skills and runtime skills both appear in build_params ──────
  # VERDICT: FIX (same root cause as test 8) — before the fix, class-level skills
  # were dropped entirely. After the fix, both class-level (_skills DSL) and
  # runtime-passed (@skills constructor param — AR model objects from context_for)
  # appear in canonical params, in that order.
  #
  # Runtime skills are the orchestrator delegation path:
  # context_for returns { skills: [...] } → ApplicationAgent.new(skills: [...])
  test "class-level skills and runtime skills passed via constructor BOTH appear in build_params" do
    dsl_skill = Class.new(ApplicationSkill) do
      skill_name "dsl_combined_test_9"
      content "Use formal English."
    end

    # Mimic an AR model skill object (the orchestrator context_for path).
    runtime_skill = Struct.new(:id, :name, :content).new(nil, "runtime_combined_test_9", "Use active voice.")

    agent_class = Class.new(WritingAgent) { skills dsl_skill }
    agent       = agent_class.new(message: "hello", skills: [runtime_skill])

    skill_names  = agent.to_canonical_params[:skills].map { |s| s[:name] }
    skill_bodies = agent.to_canonical_params[:skills].map { |s| s[:content] }

    assert_includes skill_names,  "dsl_combined_test_9",      "class-level skill must appear"
    assert_includes skill_names,  "runtime_combined_test_9",  "runtime skill must appear"
    assert_includes skill_bodies, "Use formal English.",      "class-level content must be present"
    assert_includes skill_bodies, "Use active voice.",        "runtime content must be present"
  end

  test "class-level skills appear before runtime skills in the canonical params order" do
    class_skill   = Class.new(ApplicationSkill) do
      skill_name "ordering_class_test_9b"
      content "Class first."
    end
    runtime_skill = Struct.new(:id, :name, :content).new(nil, "ordering_runtime_test_9b", "Runtime second.")

    agent_class = Class.new(WritingAgent) { skills class_skill }
    agent       = agent_class.new(message: "test", skills: [runtime_skill])
    skills      = agent.to_canonical_params[:skills]

    assert_equal "ordering_class_test_9b",   skills.first[:name], "class-level skill must come first"
    assert_equal "ordering_runtime_test_9b", skills.last[:name],  "runtime skill must come last"
  end

  # ── 10. Skill name and tool name collision ────────────────────────────────────
  # VERDICT: PASS (by design) — skills and tools occupy entirely separate namespaces.
  # Skills live in canonical[:skills] → sent as system prompt blocks.
  # Tools live in canonical[:tools]  → sent as the tools array.
  # There is no validation that detects collisions between the two.
  # The duplicate-name guard (validate_tool_names!) only checks WITHIN the tools list.
  #
  # Analogy: a recipe book and a kitchen tool can share a name ("blender recipe" and
  # "blender") without interfering — they're different data structures.
  test "a skill and a tool with the same name string coexist without error or collision" do
    shared_name_tool = Class.new(ApplicationTool) do
      tool_name "shared_name_collision_10"
      description "I am a tool"
      def call(**) = "tool result"
    end

    shared_name_skill = Class.new(ApplicationSkill) do
      skill_name "shared_name_collision_10"
      content "I am a skill with the same name."
    end

    agent_class = Class.new(WritingAgent) do
      tools  shared_name_tool
      skills shared_name_skill
    end
    agent  = agent_class.new(message: "test")
    params = nil

    begin
      params = agent.to_canonical_params
    rescue => e
      flunk "skill/tool name collision must not raise — different namespaces. Got: #{e.class} #{e.message}"
    end

    tool_names  = params[:tools].map  { |t| t[:name] }
    skill_names = params[:skills].map { |s| s[:name] }

    assert_includes tool_names,  "shared_name_collision_10", "tool must appear in :tools"
    assert_includes skill_names, "shared_name_collision_10", "skill must appear in :skills"

    # Explicitly verify they're in different sections, not collapsed.
    assert_equal 1, tool_names.count("shared_name_collision_10"),  "exactly one tool with that name"
    assert_equal 1, skill_names.count("shared_name_collision_10"), "exactly one skill with that name"
  end

  # ── 11. _skills inheritance — parent + child skills both appear ───────────────
  # VERDICT: FIX (same root cause as test 8) — class_attribute accumulation was
  # already correct (child._skills = parent._skills + child-declared skills),
  # but it was invisible because build_params ignored self.class._skills entirely.
  # After the fix, both parent and child skills flow through to canonical params.
  #
  # class_attribute works like DNA: the child receives a copy of the parent's value
  # at the moment it first writes to the attribute. Parent changes afterwards do
  # not affect the child's already-written copy.
  test "_skills declared on a parent class appear in the child agent's canonical params" do
    parent_skill = Class.new(ApplicationSkill) do
      skill_name "parent_inherited_skill_test_11a"
      content "Parent skill content."
    end

    parent_class = Class.new(WritingAgent) { skills parent_skill }
    child_class  = Class.new(parent_class)  # no additional skills declared

    skill_names = child_class.new(message: "test").to_canonical_params[:skills].map { |s| s[:name] }

    assert_includes skill_names, "parent_inherited_skill_test_11a",
      "child agent must inherit parent's class-level skills"
  end

  test "_skills from parent AND child BOTH appear — child accumulates, not overrides" do
    parent_skill = Class.new(ApplicationSkill) do
      skill_name "parent_accumulate_test_11b"
      content "Parent style."
    end

    child_skill = Class.new(ApplicationSkill) do
      skill_name "child_accumulate_test_11b"
      content "Child style."
    end

    parent_class = Class.new(WritingAgent) { skills parent_skill }
    child_class  = Class.new(parent_class) { skills child_skill }

    # Verify class attribute accumulation before checking build_params.
    assert_equal 2, child_class._skills.size,
      "child _skills must contain both parent and child declarations — not just one or both doubled"

    skill_names = child_class.new(message: "test").to_canonical_params[:skills].map { |s| s[:name] }

    assert_includes skill_names, "parent_accumulate_test_11b",
      "parent skill must survive into the child's canonical params"
    assert_includes skill_names, "child_accumulate_test_11b",
      "child skill must also appear"
    assert_equal 2, skill_names.size,
      "exactly 2 skills — no duplication, no loss"
  end

  test "parent _skills are unaffected when the child adds its own — no upward mutation" do
    common_skill = Class.new(ApplicationSkill) do
      skill_name "isolation_parent_test_11c"
      content "Parent only."
    end

    extra_skill = Class.new(ApplicationSkill) do
      skill_name "isolation_child_test_11c"
      content "Child addition."
    end

    parent_class = Class.new(WritingAgent) { skills common_skill }
    child_class  = Class.new(parent_class) { skills extra_skill }

    # Parent class_attribute must NOT have picked up the child's extra skill.
    parent_skill_names = parent_class._skills.map { |s|
      s.respond_to?(:skill_name) ? s.skill_name : s[:name]
    }
    refute_includes parent_skill_names, "isolation_child_test_11c",
      "parent class _skills must not be mutated when the child adds its own"

    # Child has both.
    child_skill_names = child_class._skills.map { |s|
      s.respond_to?(:skill_name) ? s.skill_name : s[:name]
    }
    assert_includes child_skill_names, "isolation_parent_test_11c"
    assert_includes child_skill_names, "isolation_child_test_11c"
  end
end
