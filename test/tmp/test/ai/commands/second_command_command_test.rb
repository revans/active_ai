require "test_helper"

class SecondCommandCommandTest < ActiveSupport::TestCase
  test "to_definition returns valid command shape" do
    defn = SecondCommandCommand.to_definition
    assert_equal "second_command", defn[:name]
    assert defn[:trigger].present?
    assert_includes %i[stream json], defn[:response_type]
  end

  test "call raises NotImplementedError until implemented" do
    assert_raises(NotImplementedError) { SecondCommandCommand.new.call }
  end
end
