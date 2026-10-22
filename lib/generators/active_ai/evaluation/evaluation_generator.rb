require "rails/generators"

module ActiveAI
  module Generators
    # rails generate active_ai:evaluation
    #
    # Scaffolds the same small harness into every app, so "which model is better for MY prompts?" is answered
    # the same way everywhere: `bin/rails ai:compare`. The generated code is the app's to change.
    class EvaluationGenerator < Rails::Generators::Base
      namespace "active_ai:evaluation"
      source_root File.expand_path("templates", __dir__)
      desc "Scaffolds a provider-comparison harness (rake ai:compare) into app/ai/evaluation."

      FILES = {
        "evaluation.rb.tt"   => "app/ai/evaluation.rb",
        "cases.yml.tt"       => "app/ai/evaluation/cases.yml",
        "case.rb.tt"         => "app/ai/evaluation/case.rb",
        "checks.rb.tt"       => "app/ai/evaluation/checks.rb",
        "result.rb.tt"       => "app/ai/evaluation/result.rb",
        "comparison.rb.tt"   => "app/ai/evaluation/comparison.rb",
        "report.rb.tt"       => "app/ai/evaluation/report.rb",
        "ai_evaluation.rake.tt" => "lib/tasks/ai_evaluation.rake",
        "evaluation_test.rb.tt" => "test/ai/evaluation/evaluation_test.rb"
      }.freeze

      def create_evaluation_files
        FILES.each { |source, destination| copy_file source, destination }
      end

      def show_next_steps
        say <<~NEXT

          Evaluation harness created. Next:
            1. Edit app/ai/evaluation/cases.yml: point each case at one of your agents and say what a good answer looks like.
            2. bin/rails ai:compare              # plans only: lists what would run, sends nothing
               RUN=1 bin/rails ai:compare        # makes the real calls (costs money) and writes tmp/ai_comparison/
            3. Add your product's own checks to app/ai/evaluation/checks.rb.
          Read the blind transcript (report.md) before opening key.json.
        NEXT
      end
    end
  end
end
