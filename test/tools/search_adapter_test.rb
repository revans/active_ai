require "test_helper"

class ActiveAIToolsSearchAdapterFactoryTest < ActiveSupport::TestCase
  test "raises NotConfiguredError when provider is nil" do
    error = assert_raises(ActiveAI::Tools::NotConfiguredError) { ActiveAI::Tools::SearchAdapter.for(nil) }
    assert_match(/search_provider/, error.message)
  end

  test "raises ConfigurationError for an unknown provider" do
    error = assert_raises(ActiveAI::ConfigurationError) { ActiveAI::Tools::SearchAdapter.for(:bing) }
    assert_match(/Unknown search provider/, error.message)
  end

  test "resolves each registered provider to its adapter class" do
    assert_instance_of ActiveAI::Tools::SearchAdapter::Firecrawl, ActiveAI::Tools::SearchAdapter.for(:firecrawl)
    assert_instance_of ActiveAI::Tools::SearchAdapter::Brave,     ActiveAI::Tools::SearchAdapter.for(:brave)
    assert_instance_of ActiveAI::Tools::SearchAdapter::Tavily,    ActiveAI::Tools::SearchAdapter.for(:tavily)
  end

  test "accepts a string provider name, not just a symbol" do
    assert_instance_of ActiveAI::Tools::SearchAdapter::Brave, ActiveAI::Tools::SearchAdapter.for("brave")
  end
end
