require "test_helper"

class ActiveAIToolsSearchAdapterBaseTest < ActiveSupport::TestCase
  test "search raises NotImplementedError on the base contract" do
    assert_raises(NotImplementedError) { ActiveAI::Tools::SearchAdapter::Base.new.search("query") }
  end

  test "format_results returns a no-results message for an empty array" do
    assert_equal "No results found.",
      ActiveAI::Tools::SearchAdapter::Base.new.send(:format_results, [])
  end

  test "format_results joins multiple results with a separator" do
    results = [
      { title: "A", url: "http://a.example", body: "body a" },
      { title: "B", url: "http://b.example", body: "body b" }
    ]

    formatted = ActiveAI::Tools::SearchAdapter::Base.new.send(:format_results, results)

    assert_equal "## A\nhttp://a.example\nbody a\n\n---\n\n## B\nhttp://b.example\nbody b", formatted
  end
end
