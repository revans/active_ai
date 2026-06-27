require "rails/generators"

module ActiveAI
  module Generators
    class AgentGenerator < Rails::Generators::NamedBase
      namespace "active_ai:agent"
      source_root File.expand_path("templates", __dir__)
      desc "Creates an ApplicationAgent subclass."

      def create_agent
        template "agent.rb.tt", "app/ai/agents/#{file_name}_agent.rb"
      end

      def create_agent_test
        template "agent_test.rb.tt", "test/ai/agents/#{file_name}_agent_test.rb"
      end
    end
  end
end
