require_relative "live_helper"

# One contract, run against each provider. See live_helper.rb.
module ProviderContract
  extend ActiveSupport::Concern
  include LiveHelper

  SCHEMA = { type: "object", properties: { answer: { type: "string" } }, required: [ "answer" ], additionalProperties: false }.freeze

  included do
    setup do
      skip_unless_live!(self.class::PROVIDER)
      @provider_name = self.class::PROVIDER
      @model = model_for(@provider_name)
      @available = provider_class(@provider_name).models(refresh: true, fallback: false)
      skip "model #{@model} is not available to this key; set ACTIVE_AI_LIVE_#{@provider_name.to_s.upcase}_MODEL" if @available && !@available.include?(@model)
    end

    def agent(**options) = ApplicationAgent.new(system: "Reply with exactly one word: ok", message: "ping", provider: @provider_name, model: @model, **options)

    test "model discovery lists the models this key can use" do
      assert_kind_of Array, @available
      assert_operator @available.size, :>, 0
      assert_includes @available, @model
    end

    test "a tiny completion returns text and token usage" do
      subject = agent
      assert_predicate subject.complete.strip, :present?
      assert_operator subject.last_usage[:input_tokens].to_i, :>, 0
      assert_operator subject.last_usage[:output_tokens].to_i, :>, 0
    end

    test "streaming delivers text" do
      chunks = []
      agent.stream { |event| chunks << event if event.is_a?(String) }
      assert_predicate chunks.join.strip, :present?
    end

    test "structured output returns an object matching the schema" do
      klass = Class.new(ApplicationAgent) { response_schema SCHEMA, name: "contract_reply" }
      result = klass.new(system: "Put the single word ok in the answer field.", message: "go", provider: @provider_name, model: @model).complete_structured
      assert_equal [ "answer" ], result.keys
      assert_kind_of String, result["answer"]
      assert_predicate result["answer"], :present?
    end

    test "provider_options reach the API untouched" do
      benign = @provider_name == :openai ? { user: "active-ai-contract-test" } : { metadata: { user_id: "active-ai-contract-test" } }
      subject = agent
      subject.define_singleton_method(:request_options) { benign }
      assert_predicate subject.complete.strip, :present?
    end

    %i[call stream].each do |method|
      test "an unknown model is a 404 that names the model (#{method})" do
        error = assert_raises(ActiveAI::ProviderError) { send_request(provider_class(@provider_name).new, method, canonical(model: "no-such-model-contract-test")) }
        assert_equal 404, error.status
        assert_includes error.message, "no-such-model-contract-test"
        record_fixture(@provider_name, "unknown_model_#{method}", error, expect_contains: "no-such-model-contract-test")
      end

      test "a malformed request is a 400 with the provider's reason (#{method})" do
        request = canonical(model: @model, options: { definitely_not_a_param: 1 })
        error = assert_raises(ActiveAI::ProviderError) { send_request(provider_class(@provider_name).new, method, request) }
        assert_equal 400, error.status
        assert_includes error.message, "definitely_not_a_param"
        record_fixture(@provider_name, "bad_parameter_#{method}", error, expect_contains: "definitely_not_a_param")
      end

      test "a bad key is a 401 and the message never echoes the key (#{method})" do
        error = assert_raises(ActiveAI::ProviderError) { send_request(provider_with_bad_key(@provider_name), method, canonical(model: @model)) }
        assert_equal 401, error.status
        assert error.authentication_failed?
        refute_includes error.message, BAD_KEY
        refute_includes error.message, "0123456789abcdef"
        record_fixture(@provider_name, "bad_key_#{method}", error)
      end
    end

    def send_request(provider, method, request)
      method == :call ? provider.call(request) : provider.stream(request) { }
    end
  end
end

class OpenAIContractTest < ActiveSupport::TestCase
  PROVIDER = :openai
  include ProviderContract
end

class AnthropicContractTest < ActiveSupport::TestCase
  PROVIDER = :anthropic
  include ProviderContract
end
