require "rails/generators"

module ActiveAI
  module Generators
    class CommandGenerator < Rails::Generators::NamedBase
      namespace "active_ai:command"
      source_root File.expand_path("templates", __dir__)
      desc "Creates an ApplicationCommand subclass and its test file."

      def create_application_command
        return if File.exist?(File.join(destination_root, "app/ai/commands/application_command.rb"))

        template "application_command.rb.tt", "app/ai/commands/application_command.rb"
      end

      def create_command
        template "command.rb.tt", "app/ai/commands/#{file_name}_command.rb"
      end

      def create_command_test
        template "command_test.rb.tt", "test/ai/commands/#{file_name}_command_test.rb"
      end
    end
  end
end
