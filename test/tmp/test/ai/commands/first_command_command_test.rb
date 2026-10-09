require "test_helper"

class FirstCommandCommandTest < ActiveSupport::TestCase
  test "to_definition returns valid command shape" do
    defn = FirstCommandCommand.to_definition
    assert_equal "first_command", defn[:name]
    assert defn[:trigger].present?
    assert_includes %i[stream json], defn[:response_type]
  end

  test "call raises NotImplementedError until implemented" do
    assert_raises(NotImplementedError) { FirstCommandCommand.new.call }
  end
end
