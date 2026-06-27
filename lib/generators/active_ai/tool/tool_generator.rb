require "rails/generators"

module ActiveAI
  module Generators
    class ToolGenerator < Rails::Generators::NamedBase
      namespace "active_ai:tool"
      source_root File.expand_path("templates", __dir__)
      desc <<~DESC
        Creates an ApplicationTool subclass and its test file.

        Note: ActiveAI ships two built-in tools — use them directly instead of generating:
          tool ActiveAI::Tools::WebSearch      # requires FIRECRAWL_API_KEY
          tool ActiveAI::Tools::WebPageReader  # no key required
      DESC

      BUILTIN_NAMES = %w[web_search read_webpage].freeze

      def check_reserved_name
        if BUILTIN_NAMES.include?(file_name)
          say_status :conflict, "#{file_name} is a built-in ActiveAI tool — use `tool ActiveAI::Tools::#{class_name}` instead of generating a custom one.", :red
          exit 1
        end
      end

      def create_tool
        template "tool.rb.tt", "app/ai/tools/#{file_name}_tool.rb"
      end

      def create_tool_test
        template "tool_test.rb.tt", "test/ai/tools/#{file_name}_tool_test.rb"
      end
    end
  end
end
