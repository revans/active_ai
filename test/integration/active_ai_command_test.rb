require "test_helper"

# Unit coverage for ActiveAI::Command::Base — the identity DSL, trigger DSL,
# response_type DSL, self-registration, and the ActiveAI.commands registry
# accessor. Follows the same pattern as the Tool::Base DSL coverage in
# active_ai_edge_cases_test.rb: dynamically-defined classes off the dummy
# app's ApplicationCommand, exercised directly (no controller layer needed —
# document:/controller: injection is an app-level concern, not a gem one).
class ActiveAICommandTest < ActiveSupport::TestCase
  test "command_name DSL stores and returns the declared name" do
    klass = Class.new(ApplicationCommand) { command_name "ping_command" }
    assert_equal "ping_command", klass.command_name
  end

  test "command_name raises NotImplementedError when never declared" do
    klass = Class.new(ApplicationCommand)
    assert_raises(NotImplementedError) { klass.command_name }
  end

  class DescribedCommandTest < ApplicationCommand
    command_name "described_command"
    description "A test command"
  end

  test "description DSL self-registers the class via Describable" do
    assert_equal "A test command", DescribedCommandTest.description
    assert_equal DescribedCommandTest, ActiveAI.registry[DescribedCommandTest.name]
  end

  test "trigger phrase: stores a phrase-type trigger hash" do
    klass = Class.new(ApplicationCommand) { trigger phrase: "/do thing" }
    assert_equal({ type: :phrase, phrase: "/do thing" }, klass.trigger)
  end

  test "trigger prefix: stores a prefix-type trigger hash" do
    klass = Class.new(ApplicationCommand) { trigger prefix: "/search" }
    assert_equal({ type: :prefix, prefix: "/search" }, klass.trigger)
  end

  test "trigger raises ArgumentError when both phrase: and prefix: are given" do
    klass = Class.new(ApplicationCommand)
    assert_raises(ArgumentError) { klass.trigger(phrase: "/a", prefix: "/b") }
  end

  test "trigger raises NotImplementedError when never declared" do
    klass = Class.new(ApplicationCommand)
    assert_raises(NotImplementedError) { klass.trigger }
  end

  test "response_type accepts :stream and :json" do
    stream_klass = Class.new(ApplicationCommand) { response_type :stream }
    json_klass   = Class.new(ApplicationCommand) { response_type :json }
    assert_equal :stream, stream_klass.response_type
    assert_equal :json,   json_klass.response_type
  end

  test "response_type raises ArgumentError for any other value" do
    klass = Class.new(ApplicationCommand)
    assert_raises(ArgumentError) { klass.response_type(:websocket) }
  end

  test "response_type raises NotImplementedError when never declared" do
    klass = Class.new(ApplicationCommand)
    assert_raises(NotImplementedError) { klass.response_type }
  end

  test "to_definition returns the Anthropic-tool-definition-style hash" do
    klass = Class.new(ApplicationCommand) do
      command_name "search_command"
      description "Searches for a query"
      trigger prefix: "/search"
      response_type :json
    end

    assert_equal({
      name:          "search_command",
      trigger:       { type: :prefix, prefix: "/search" },
      response_type: :json
    }, klass.to_definition)
  end

  test "call raises NotImplementedError on the base contract" do
    klass = Class.new(ApplicationCommand)
    assert_raises(NotImplementedError) { klass.new.call }
  end

  test "instance delegates expose the same identity interface as the class" do
    klass = Class.new(ApplicationCommand) do
      command_name "delegate_command"
      description "Delegate test"
      trigger phrase: "/delegate"
      response_type :stream
    end
    instance = klass.new

    assert_equal "delegate_command", instance.command_name
    assert_equal "Delegate test",    instance.description
    assert_equal({ type: :phrase, phrase: "/delegate" }, instance.trigger)
    assert_equal :stream, instance.response_type
    assert_equal klass.to_definition, instance.to_definition
  end

  class RegistryCommandTest < ApplicationCommand
    command_name "registry_command"
    description "In the registry"
    trigger phrase: "/registry"
    response_type :json
  end

  test "ActiveAI.commands returns only registered Command::Base descendants" do
    assert_includes ActiveAI.commands, RegistryCommandTest
    assert_empty ActiveAI.commands.select { |k| k < ActiveAI::Tool::Base }
  end

  test "ActiveAI::Command::Base is not itself a Tool::Base or Agent::Base descendant" do
    refute ActiveAI::Command::Base < ActiveAI::Tool::Base
    refute ActiveAI::Command::Base < ActiveAI::Agent::Base
  end
end
