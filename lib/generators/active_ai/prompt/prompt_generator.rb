require "rails/generators"

module ActiveAI
  module Generators
    class PromptGenerator < Rails::Generators::Base
      namespace "active_ai:prompt"
      source_root File.expand_path("templates", __dir__)
      desc "Creates a prompt file in the correct app/ai/<namespace>/prompts/ directory."

      argument :prompt_namespace, type: :string,
               desc: "Namespace: agent, skill, orchestrator, workflow, tool, memory"
      argument :prompt_name, type: :string,
               desc: "Prompt name in snake_case (e.g. writing, tone_guidelines)"

      NAMESPACE_DIRS = {
        "agent"        => "app/ai/agents/prompts",
        "tool"         => "app/ai/tools/prompts",
        "skill"        => "app/ai/skills/prompts",
        "memory"       => "app/ai/memory/prompts",
        "workflow"     => "app/ai/workflows/prompts",
        "orchestrator" => "app/ai/orchestrators/prompts"
      }.freeze

      # Skills render without instance context — prompt_file sets _static_content at class load time.
      CLASS_LEVEL_NAMESPACES = %w[skill].freeze

      def create_prompt_file
        unless NAMESPACE_DIRS.key?(prompt_namespace)
          say_status :error,
            "Unknown namespace #{prompt_namespace.inspect}. " \
            "Valid namespaces: #{NAMESPACE_DIRS.keys.join(', ')}",
            :red
          exit 1
        end

        @class_level = CLASS_LEVEL_NAMESPACES.include?(prompt_namespace)
        dir          = NAMESPACE_DIRS[prompt_namespace]
        file_name    = normalized_name

        template template_name, "#{dir}/#{file_name}.md.erb"
      end

      private

      def normalized_name
        prompt_name.underscore.tr("-", "_")
      end

      def template_name
        @class_level ? "static_prompt.md.erb.tt" : "instance_prompt.md.erb.tt"
      end
    end
  end
end
