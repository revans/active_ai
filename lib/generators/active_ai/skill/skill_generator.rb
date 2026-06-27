require "rails/generators"

module ActiveAI
  module Generators
    class SkillGenerator < Rails::Generators::NamedBase
      namespace "active_ai:skill"
      source_root File.expand_path("templates", __dir__)
      desc "Creates an ApplicationSkill subclass and its test file."

      def create_skill
        template "skill.rb.tt", "app/ai/skills/#{file_name}_skill.rb"
      end

      def create_skill_test
        template "skill_test.rb.tt", "test/ai/skills/#{file_name}_skill_test.rb"
      end
    end
  end
end
