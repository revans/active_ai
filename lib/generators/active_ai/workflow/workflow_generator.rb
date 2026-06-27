require "rails/generators"

module ActiveAI
  module Generators
    class WorkflowGenerator < Rails::Generators::NamedBase
      namespace "active_ai:workflow"
      source_root File.expand_path("templates", __dir__)
      desc "Creates an ApplicationWorkflow subclass and its test file."

      def create_workflow
        template "workflow.rb.tt", "app/ai/workflows/#{file_name}_workflow.rb"
      end

      def create_workflow_test
        template "workflow_test.rb.tt", "test/ai/workflows/#{file_name}_workflow_test.rb"
      end
    end
  end
end
