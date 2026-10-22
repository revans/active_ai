require "test_helper"
require "tmpdir"
require "rails/generators/test_case"
require "generators/active_ai/command/command_generator"

# Tests for the active_ai:command generator.
#
#   rails generate active_ai:command <Name>
#
# Analogy: a command is like a light switch installed in a wall — it only
# gets wired in when someone explicitly asks an electrician to add one, unlike
# the outlets (tools, agents) that come standard with the house. These tests
# verify the switch, its plate (ApplicationCommand), and its test all land in
# the right place, and that the plate is only installed once.
class ActiveAICommandGeneratorTest < Rails::Generators::TestCase
  tests ActiveAI::Generators::CommandGenerator
  destination File.join(Dir.tmpdir, "active_ai_generator_tests_#{Process.pid}")
  setup :prepare_destination

  test "creates the command file" do
    run_generator %w[leave_editor]
    assert_file "app/ai/commands/leave_editor_command.rb" do |content|
      assert_match(/class LeaveEditorCommand < ApplicationCommand/, content)
      assert_match(/command_name "leave_editor"/, content)
    end
  end

  test "creates the command test file" do
    run_generator %w[leave_editor]
    assert_file "test/ai/commands/leave_editor_command_test.rb" do |content|
      assert_match(/class LeaveEditorCommandTest < ActiveSupport::TestCase/, content)
    end
  end

  test "creates ApplicationCommand when it does not yet exist" do
    run_generator %w[leave_editor]
    assert_file "app/ai/commands/application_command.rb" do |content|
      assert_match(/class ApplicationCommand < ActiveAI::Command::Base/, content)
    end
  end

  test "does not overwrite an existing ApplicationCommand" do
    run_generator %w[first_command]
    path = File.join(destination_root, "app/ai/commands/application_command.rb")
    File.write(path, "class ApplicationCommand < ActiveAI::Command::Base\n  # customized\nend\n")

    run_generator %w[second_command]

    assert_match(/# customized/, File.read(path))
  end

  test "camel-case name is normalized to snake_case" do
    run_generator %w[LeaveEditor]
    assert_file "app/ai/commands/leave_editor_command.rb"
  end
end
