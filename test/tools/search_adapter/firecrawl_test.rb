require "test_helper"

class ActiveAIToolsSearchAdapterFirecrawlTest < ActiveSupport::TestCase
  include NetHttpStub

  setup do
    @adapter = ActiveAI::Tools::SearchAdapter::Firecrawl.new
    @original_env_key    = ENV.delete("FIRECRAWL_API_KEY")
    @original_config_key = ActiveAI.config.search_api_key
    ActiveAI.config.search_api_key = nil
  end

  teardown do
    ENV["FIRECRAWL_API_KEY"] = @original_env_key
    ActiveAI.config.search_api_key = @original_config_key
  end

  test "raises NotConfiguredError when neither ENV nor config has an API key" do
    error = assert_raises(ActiveAI::Tools::NotConfiguredError) { @adapter.search("ruby") }
    assert_match(/FIRECRAWL_API_KEY/, error.message)
  end

  test "falls back to the ENV var when config.search_api_key is not set" do
    ENV["FIRECRAWL_API_KEY"] = "env-key"

    stub_net_http_response(response_class: Net::HTTPOK, body: { data: [] }.to_json) do
      assert_equal "No results found.", @adapter.search("ruby")
    end
  end

  test "config.search_api_key takes precedence over the ENV var" do
    ENV["FIRECRAWL_API_KEY"] = "env-key"
    ActiveAI.config.search_api_key = "config-key"
    seen_auth = nil

    stub_net_http_response(response_class: Net::HTTPOK, body: { data: [] }.to_json,
                            on_request: ->(request) { seen_auth = request["Authorization"] }) do
      @adapter.search("ruby")
    end

    assert_equal "Bearer config-key", seen_auth
  end

  test "parses a successful response, preferring markdown over description" do
    ENV["FIRECRAWL_API_KEY"] = "env-key"
    body = { data: [{ "title" => "Ruby", "url" => "https://ruby-lang.org", "markdown" => "md body", "description" => "desc body" }] }.to_json

    stub_net_http_response(response_class: Net::HTTPOK, body: body) do
      result = @adapter.search("ruby")
      assert_equal "## Ruby\nhttps://ruby-lang.org\nmd body", result
    end
  end

  test "falls back to description when markdown is blank" do
    ENV["FIRECRAWL_API_KEY"] = "env-key"
    body = { data: [{ "title" => "Ruby", "url" => "https://ruby-lang.org", "markdown" => "", "description" => "desc body" }] }.to_json

    stub_net_http_response(response_class: Net::HTTPOK, body: body) do
      result = @adapter.search("ruby")
      assert_equal "## Ruby\nhttps://ruby-lang.org\ndesc body", result
    end
  end

  test "returns a no-results message on a non-success HTTP response" do
    ENV["FIRECRAWL_API_KEY"] = "env-key"

    stub_net_http_response(response_class: Net::HTTPUnauthorized, body: "unauthorized") do
      assert_equal "No results found.", @adapter.search("ruby")
    end
  end

  test "returns a no-results message on a 500 response" do
    ENV["FIRECRAWL_API_KEY"] = "env-key"

    stub_net_http_response(response_class: Net::HTTPInternalServerError, body: "boom") do
      assert_equal "No results found.", @adapter.search("ruby")
    end
  end

  test "returns a no-results message instead of raising on malformed JSON" do
    ENV["FIRECRAWL_API_KEY"] = "env-key"

    stub_net_http_response(response_class: Net::HTTPOK, body: "not json") do
      assert_equal "No results found.", @adapter.search("ruby")
    end
  end

  test "returns a no-results message instead of raising on a network timeout" do
    ENV["FIRECRAWL_API_KEY"] = "env-key"

    stub_net_http_raise(Net::OpenTimeout.new("timed out")) do
      assert_equal "No results found.", @adapter.search("ruby")
    end
  end
end
