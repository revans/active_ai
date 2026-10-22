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
      skip "model #{@model} is not available to this key; set ACTIVE_AI_LIVE_#{@provider_name.to_s.upcase}_MODELS" if @available && !@available.include?(@model)
    end

    def agent(model: @model, **options) = ApplicationAgent.new(system: "Reply with exactly one word: ok", message: "ping", provider: @provider_name, model: model, **options)

    def skip_unless_available!(model)
      skip "model #{model} is not available to this key" if @available && !@available.include?(model)
    end

    test "model discovery lists the models this key can use" do
      assert_kind_of Array, @available
      assert_operator @available.size, :>, 0
      assert_includes @available, @model
    end

    LiveHelper.models_for(self::PROVIDER).each do |model|
      test "a tiny completion returns text and token usage (#{model})" do
        skip_unless_available!(model)
        subject = agent(model: model)
        assert_predicate subject.complete.strip, :present?
        assert_operator subject.last_usage[:input_tokens].to_i, :>, 0
        assert_operator subject.last_usage[:output_tokens].to_i, :>, 0
      end

      test "structured output returns an object matching the schema (#{model})" do
        skip_unless_available!(model)
        klass = Class.new(ApplicationAgent) { response_schema SCHEMA, name: "contract_reply" }
        result = klass.new(system: "Put the single word ok in the answer field.", message: "go", provider: @provider_name, model: model).complete_structured
        assert_equal [ "answer" ], result.keys
        assert_kind_of String, result["answer"]
        assert_predicate result["answer"], :present?
      end
    end

    LiveHelper.models_for(self::PROVIDER).each do |model|
      test "max_tokens :unlimited is accepted and the model answers (#{model})" do
        skip_unless_available!(model)
        unlimited = Class.new(ApplicationAgent) { max_tokens :unlimited }
        response = unlimited.new(system: "Reply with exactly one word: ok", message: "ping", provider: @provider_name, model: model).generate
        assert response.complete?, "finish_reason was #{response.finish_reason.inspect} (provider said #{response.raw_finish_reason.inspect})"
        assert_predicate response.text.strip, :present?
      end

      test "generate reports who answered, which model served it, and why it stopped (#{model})" do
        skip_unless_available!(model)
        response = agent(model: model).generate
        assert_kind_of ActiveAI::Response, response
        assert_equal @provider_name, response.provider
        assert_equal model, response.requested_model
        assert_predicate response.model, :present?, "the provider should report the model that served the request"
        assert response.complete?, "finish_reason was #{response.finish_reason.inspect} (provider said #{response.raw_finish_reason.inspect})"
        assert_includes %w[stop end_turn], response.raw_finish_reason
        assert_operator response.usage[:input_tokens], :>, 0
        assert_predicate response.request_id, :present?
        assert_operator response.latency, :>, 0
        assert_operator response.end_time, :>, response.start_time
        assert_in_delta response.latency, response.end_time - response.start_time, 0.05
        assert_match(/\.\d{3}Z\z/, response.as_json["start_time"], "times render with milliseconds")
        assert_in_delta Time.now.utc, response.end_time, 60, "the times are real wall-clock times"
      end
    end

    test "a truncated answer comes back as a response, not an error (limit set with the max_tokens DSL)" do
      capped = Class.new(ApplicationAgent) { max_tokens 20 }
      subject = capped.new(system: "Follow instructions exactly.", message: "Count from 1 to 300, separated by commas, no other words.", provider: @provider_name, model: @model)
      response = subject.generate
      assert response.truncated?, "finish_reason was #{response.finish_reason.inspect} (provider said #{response.raw_finish_reason.inspect})"
      assert_includes %w[length max_tokens], response.raw_finish_reason
      assert_operator response.usage[:output_tokens], :>=, 20
    end

    test "streaming delivers text" do
      chunks = []
      agent.stream { |event| chunks << event if event.is_a?(String) }
      assert_predicate chunks.join.strip, :present?
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
