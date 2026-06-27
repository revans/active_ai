module ActiveAI
  # Included in ApplicationAgent, ApplicationTool, etc. so instances can render
  # prompt files from their own directory with full access to their own state.
  #
  #   class ApplicationAgent < ActiveAI::Base
  #     include ActiveAI::Promptable
  #     prompt_namespace :agent
  #   end
  #
  # Then in any subclass instance:
  #
  #   def build_params
  #     { system: prompt_file(:my_agent), ... }
  #   end
  #
  # The ERB template at app/ai/agents/prompts/my_agent.md.erb renders with
  # self == the agent instance, so resolved_model, @user, etc. are all in scope.
  #
  module Promptable
    extend ActiveSupport::Concern

    included do
      class_attribute :_prompt_namespace
    end

    class_methods do
      def prompt_namespace(ns)
        self._prompt_namespace = ns.to_sym
      end
    end

    def prompt_file(name, **locals)
      namespace = self.class._prompt_namespace
      raise ActiveAI::ConfigurationError,
            "prompt_namespace not set on #{self.class} — call `prompt_namespace :agent` (or :tool, :memory, etc.)" unless namespace

      ActiveAI.public_send(namespace)._prompt_in_context(name, self, **locals)
    end
  end
end
