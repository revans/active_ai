require "test_helper"
require "tmpdir"
require "rails/generators/test_case"
require "generators/active_ai/evaluation/evaluation_generator"

# rails generate active_ai:evaluation
#
# Analogy: this hands every app the same scale to weigh its prompts on. The tests check the scale gets installed in
# the right places, and then actually weigh something with it, so the scaffold is known to work and not just to exist.
class ActiveAIEvaluationGeneratorTest < Rails::Generators::TestCase
  include ActiveAI::TestHelper

  tests ActiveAI::Generators::EvaluationGenerator
  destination File.join(Dir.tmpdir, "active_ai_generator_tests_#{Process.pid}")
  setup :prepare_destination
  teardown { Object.send(:remove_const, :Evaluation) if Object.const_defined?(:Evaluation) }

  LOAD_ORDER = %w[evaluation.rb evaluation/checks.rb evaluation/result.rb evaluation/case.rb evaluation/comparison.rb evaluation/report.rb].freeze

  def load_generated
    LOAD_ORDER.each { |file| load File.join(destination_root, "app/ai", file) }
  end

  def generated_cases = Evaluation::Case.all(File.join(destination_root, "app/ai/evaluation/cases.yml"))

  test "creates the whole harness in the conventional places" do
    run_generator
    %w[app/ai/evaluation.rb app/ai/evaluation/cases.yml app/ai/evaluation/case.rb app/ai/evaluation/checks.rb
       app/ai/evaluation/result.rb app/ai/evaluation/comparison.rb app/ai/evaluation/report.rb
       lib/tasks/ai_evaluation.rake test/ai/evaluation/evaluation_test.rb].each { |path| assert_file path }
    assert_file "app/ai/evaluation/result.rb", /class Evaluation::Result/
    assert_file "lib/tasks/ai_evaluation.rake", /task compare: :environment/
  end

  test "every generated Ruby file is valid Ruby" do
    run_generator
    Dir[File.join(destination_root, "{app,lib,test}/**/*.{rb,rake}")].each do |path|
      begin
        RubyVM::InstructionSequence.compile_file(path)
      rescue SyntaxError => error
        flunk "#{path} does not compile: #{error.message}"
      end
    end
  end

  test "the generated cases file parses and the starter case is valid" do
    run_generator
    load_generated
    starter = generated_cases.first
    assert_equal "smoke_test", starter.id
    starter.checks.each do |specification|
      name = specification.is_a?(Hash) ? specification.keys.first : specification
      assert Evaluation::Checks.method_defined?("check_#{name}"), "starter case names a check that does not exist: #{name}"
    end
  end

  test "the generic checks pass a good answer and catch a cut-off, an over-budget, and a missing one" do
    run_generator
    load_generated
    starter = generated_cases.first
    good = Evaluation::Result.new(evaluation_case: starter, provider: "openai", response: build_ai_response(text: "ok"))
    assert_equal good.total_count, good.passed_count, good.outcomes.reject { |_, o| o.passed }.inspect

    cut = Evaluation::Result.new(evaluation_case: starter, provider: "openai", response: build_ai_response(text: "o", finish_reason: :truncated, raw_finish_reason: "length"))
    assert_not cut.outcomes["finished"].passed
    assert_match "length", cut.outcomes["finished"].detail

    slow = Evaluation::Result.new(evaluation_case: starter, provider: "openai", response: build_ai_response(text: "ok", latency: 99))
    assert_not slow.outcomes["max_seconds"].passed

    missing = Evaluation::Result.new(evaluation_case: starter, provider: "openai", response: build_ai_response(text: "nope"))
    assert_not missing.outcomes["contains"].passed
  end

  test "each generic check behaves" do
    run_generator
    load_generated
    result = Evaluation::Result.new(evaluation_case: generated_cases.first, provider: "p", response: build_ai_response(text: "Hello World", data: { "a" => 1 }, usage: { output_tokens: 30 }))
    assert result.check_structured.passed
    assert result.check_max_output_tokens(tokens: 30).passed
    assert_not result.check_max_output_tokens(tokens: 29).passed
    assert result.check_contains(text: "hello").passed
    assert result.check_excludes(text: "goodbye").passed
    assert_not result.check_excludes(text: "WORLD").passed
    assert result.check_matches(pattern: "h.llo").passed
    assert_not result.check_matches(pattern: "^world").passed
    assert_not Evaluation::Result.new(evaluation_case: generated_cases.first, provider: "p", response: build_ai_response(data_error: "bad")).check_structured.passed
  end

  test "asking runs the agent, and a provider failure becomes a failed result instead of stopping the run" do
    run_generator
    load_generated
    evaluation_case = generated_cases.first

    agent = ApplicationAgent.new(system: "s", message: "hi")
    stub_ai_response(agent, response: "ok")
    evaluation_case.define_singleton_method(:build_agent) { |_provider, _model| agent }
    result = evaluation_case.ask(provider: "openai")
    assert result.answered?
    assert_equal "ok", result.response.text

    evaluation_case.define_singleton_method(:build_agent) { |_provider, _model| raise ActiveAI::ProviderError.new("OpenAI: HTTP 401: bad key") }
    failed = evaluation_case.ask(provider: "openai")
    assert_not failed.answered?
    assert_match "bad key", failed.failure.message
  end

  test "planning sends nothing, and the plan lists providers, cases and call count" do
    run_generator
    load_generated
    comparison = Evaluation::Comparison.new(cases: generated_cases, runs: 3)
    assert_equal 2 * 1 * 3, comparison.planned_calls
    plan = comparison.plan
    assert_match "plan only, nothing sent", plan
    assert_match "smoke_test", plan
    assert_match "6 real API calls", plan
    assert_kind_of Array, comparison.missing_keys
  end

  test "a comparison runs every case, provider and repeat, and the report keeps the transcript blind" do
    run_generator
    load_generated
    evaluation_case = generated_cases.first
    responses = { "openai" => build_ai_response(text: "ok", provider: :openai), "anthropic" => build_ai_response(text: "o", provider: :anthropic) }
    evaluation_case.define_singleton_method(:ask) do |provider:, model: nil|
      Evaluation::Result.new(evaluation_case: self, provider: provider, response: responses.fetch(provider))
    end

    seen = []
    report = Evaluation::Comparison.new(cases: [ evaluation_case ], runs: 2).compare { |result| seen << result.run_number }
    assert_equal [ 1, 2, 1, 2 ], seen
    assert_equal %w[openai anthropic], report.providers

    card = report.scorecard
    assert_match(/openai\s+anthropic/, card)
    assert_match "contains", card, "the failing check for the short answer is listed"

    Dir.mktmpdir do |directory|
      report.write(directory)
      assert_equal %w[key.json report.md results.json], Dir.children(directory).sort
      transcript = File.read(File.join(directory, "report.md"))
      assert_no_match(/openai|anthropic/i, transcript)
      assert_match(/Model [AB], run 1/, transcript)
      assert_equal %w[anthropic openai], JSON.parse(File.read(File.join(directory, "key.json"))).values.sort
      assert_equal 4, JSON.parse(File.read(File.join(directory, "results.json"))).size
    end
  end

  test "rerunning does not clobber a file the app has edited" do
    run_generator
    path = File.join(destination_root, "app/ai/evaluation/checks.rb")
    File.write(path, "# my own checks\n")
    run_generator [ "--skip" ]
    assert_equal "# my own checks\n", File.read(path)
  end
end
