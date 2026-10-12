require "test_helper"

class ModelDiscoveryTest < ActiveSupport::TestCase
  include NetHttpStub

  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown { Rails.cache = @previous_cache }

  test "discovery isolates credentials and can refresh without exposing keys in cache" do
    calls = []
    stub_net_http_response(response_class: Net::HTTPOK, body: { data: [{ id: "future-chat-model" }] }.to_json,
      on_request: ->(request) { calls << request["Authorization"] }) do
      provider = ActiveAI::Provider::OpenAI
      assert_equal ["future-chat-model"], provider.models(api_key: "account-one", fallback: false)
      provider.models(api_key: "account-one")
      provider.models(api_key: "account-two")
      provider.models(api_key: "account-one", refresh: true)
      assert_equal ["Bearer account-one", "Bearer account-two", "Bearer account-one"], calls
      refute Rails.cache.instance_variable_get(:@data).keys.any? { |key| key.include?("account-") }
    end
  end

  test "failure is explicit without fallback and is not cached as a live list" do
    provider = ActiveAI::Provider::OpenAI
    stub_net_http_response(response_class: Net::HTTPUnauthorized, body: "private error") do
      assert_nil provider.models(api_key: "invalid", fallback: false)
      assert_equal provider.model_defaults, provider.models(api_key: "invalid")
    end
    stub_net_http_response(response_class: Net::HTTPOK, body: '{"data":[{"id":"new-model"}]}') do
      assert_equal ["new-model"], provider.models(api_key: "invalid", fallback: false)
    end
  end

  test "OpenAI and xAI return every listed ID including new families and fine tunes" do
    [ActiveAI::Provider::OpenAI, ActiveAI::Provider::XAI].each do |provider|
      stub_net_http_response(response_class: Net::HTTPOK, body: { data: [{ id: "new-family" }, { id: "ft:custom:model" }, { id: "new-family" }] }.to_json) do
        assert_equal ["ft:custom:model", "new-family"], provider.fetch_models(api_key: "test-key")
      end
    end
  end

  test "Anthropic follows all pages" do
    requests = []
    with_fake_net_http(->(request) do
      requests << request.path
      body = requests.length == 1 ? { data: [{ id: "first" }], has_more: true, last_id: "first" } : { data: [{ id: "second" }], has_more: false }
      response = Net::HTTPOK.allocate
      response.instance_variable_set(:@body, body.to_json)
      response.instance_variable_set(:@read, true)
      response
    end) do
      assert_equal %w[first second], ActiveAI::Provider::Anthropic.fetch_models(api_key: "test-key")
      assert_includes requests.last, "after_id=first"
    end
  end

  test "invalid data and pagination loops fail without returning a partial catalog" do
    ["not json", '{"data":null}', '{"data":[{}]}', '{"data":[{"id":"x"}],"has_more":true,"last_id":"x"}'].each do |body|
      stub_net_http_response(response_class: Net::HTTPOK, body: body) do
        assert_nil ActiveAI::Provider::Anthropic.fetch_models(api_key: "test-key")
      end
    end
  end
end
