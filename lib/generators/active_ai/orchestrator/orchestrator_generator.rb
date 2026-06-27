require "rails/generators"

module ActiveAI
  module Generators
    class OrchestratorGenerator < Rails::Generators::NamedBase
      namespace "active_ai:orchestrator"
      source_root File.expand_path("templates", __dir__)
      desc "Creates an ApplicationOrchestrator subclass and its test file."

      def create_orchestrator
        template "orchestrator.rb.tt", "app/ai/orchestrators/#{file_name}_orchestrator.rb"
      end

      def create_orchestrator_test
        template "orchestrator_test.rb.tt", "test/ai/orchestrators/#{file_name}_orchestrator_test.rb"
      end
    end
  end
end
