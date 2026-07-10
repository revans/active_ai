require "test_helper"

class ActiveAIToolsSearchAdapterTavilyTest < ActiveSupport::TestCase
  include NetHttpStub

  setup do
    @adapter = ActiveAI::Tools::SearchAdapter::Tavily.new
    @original_env_key    = ENV.delete("TAVILY_API_KEY")
    @original_config_key = ActiveAI.config.search_api_key
    ActiveAI.config.search_api_key = nil
  end

  teardown do
    ENV["TAVILY_API_KEY"] = @original_env_key
    ActiveAI.config.search_api_key = @original_config_key
  end

  test "raises NotConfiguredError when neither ENV nor config has an API key" do
    error = assert_raises(ActiveAI::Tools::NotConfiguredError) { @adapter.search("ruby") }
    assert_match(/TAVILY_API_KEY/, error.message)
  end

  test "falls back to the ENV var when config.search_api_key is not set" do
    ENV["TAVILY_API_KEY"] = "env-key"

    stub_net_http_response(response_class: Net::HTTPOK, body: { results: [] }.to_json) do
      assert_equal "No results found.", @adapter.search("ruby")
    end
  end

  test "config.search_api_key takes precedence over the ENV var" do
    ENV["TAVILY_API_KEY"] = "env-key"
    ActiveAI.config.search_api_key = "config-key"
    seen_key = nil

    stub_net_http_response(response_class: Net::HTTPOK, body: { results: [] }.to_json,
                            on_request: ->(request) { seen_key = JSON.parse(request.body)["api_key"] }) do
      @adapter.search("ruby")
    end

    assert_equal "config-key", seen_key
  end

  test "parses a successful response into formatted results" do
    ENV["TAVILY_API_KEY"] = "env-key"
    body = { results: [{ "title" => "Ruby", "url" => "https://ruby-lang.org", "content" => "A language" }] }.to_json

    stub_net_http_response(response_class: Net::HTTPOK, body: body) do
      result = @adapter.search("ruby")
      assert_equal "## Ruby\nhttps://ruby-lang.org\nA language", result
    end
  end

  test "returns a no-results message on a non-success HTTP response" do
    ENV["TAVILY_API_KEY"] = "env-key"

    stub_net_http_response(response_class: Net::HTTPUnauthorized, body: "unauthorized") do
      assert_equal "No results found.", @adapter.search("ruby")
    end
  end

  test "returns a no-results message on a 500 response" do
    ENV["TAVILY_API_KEY"] = "env-key"

    stub_net_http_response(response_class: Net::HTTPInternalServerError, body: "boom") do
      assert_equal "No results found.", @adapter.search("ruby")
    end
  end

  test "returns a no-results message instead of raising on malformed JSON" do
    ENV["TAVILY_API_KEY"] = "env-key"

    stub_net_http_response(response_class: Net::HTTPOK, body: "not json") do
      assert_equal "No results found.", @adapter.search("ruby")
    end
  end

  test "returns a no-results message instead of raising on a network timeout" do
    ENV["TAVILY_API_KEY"] = "env-key"

    stub_net_http_raise(Net::OpenTimeout.new("timed out")) do
      assert_equal "No results found.", @adapter.search("ruby")
    end
  end
end
