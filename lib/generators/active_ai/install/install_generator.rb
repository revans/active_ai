require "rails/generators"

module ActiveAI
  module Generators
    class InstallGenerator < Rails::Generators::Base
      namespace "active_ai:install"
      source_root File.expand_path("templates", __dir__)
      desc "Creates the ActiveAI configuration and base app files."

      def create_config
        template "ai.yml", "config/ai.yml"
      end

      def create_initializer
        template "active_ai.rb", "config/initializers/active_ai.rb"
      end

      def create_application_agent
        template "application_agent.rb", "app/ai/agents/application_agent.rb"
      end

      def create_application_tool
        template "application_tool.rb", "app/ai/tools/application_tool.rb"
      end

      def create_application_skill
        template "application_skill.rb", "app/ai/skills/application_skill.rb"
      end

      def create_application_workflow
        template "application_workflow.rb", "app/ai/workflows/application_workflow.rb"
      end

      def create_application_orchestrator
        template "application_orchestrator.rb", "app/ai/orchestrators/application_orchestrator.rb"
      end
    end
  end
end
