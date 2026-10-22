require "test_helper"

# The Response assertions and the build_ai_response factory in ActiveAI::TestHelper.
class ResponseAssertionsTest < ActiveSupport::TestCase
  include ActiveAI::TestHelper

  def failure_message
    error = assert_raises(Minitest::Assertion) { yield }
    error.message
  end

  test "build_ai_response defaults to a complete answer and takes overrides" do
    response = build_ai_response
    assert response.complete?
    assert_equal :test, response.provider
    assert_equal "ok", response.text
    assert_equal :truncated, build_ai_response(finish_reason: :truncated).finish_reason
    assert_equal "length", build_ai_response(finish_reason: :truncated, raw_finish_reason: "length").raw_finish_reason
    assert_equal({ "a" => 1 }, build_ai_response(data: { "a" => 1 }).data)
  end

  test "assert_ai_complete passes a complete response and explains an incomplete one" do
    assert_ai_complete build_ai_response
    message = failure_message { assert_ai_complete build_ai_response(finish_reason: :truncated, raw_finish_reason: "length", text: "1, 2, 3") }
    assert_match "finish_reason was :truncated", message
    assert_match 'provider said "length"', message
    assert_match '"1, 2, 3"', message
    assert_match "served by test/", message
  end

  test "a refusal is explained with its reason" do
    message = failure_message { assert_ai_complete build_ai_response(finish_reason: :refused, refusal: "I can't help with that.", text: "") }
    assert_match "refusal: \"I can't help with that.\"", message
  end

  test "assert_ai_finish_reason" do
    assert_ai_finish_reason build_ai_response(finish_reason: :truncated), :truncated
    assert_match "Expected finish_reason :truncated", failure_message { assert_ai_finish_reason build_ai_response, :truncated }
  end

  test "assert_ai_structured passes with data and says why when there is none" do
    assert_ai_structured build_ai_response(data: { "a" => 1 })
    assert_match "data_error: the answer was not valid JSON", failure_message { assert_ai_structured build_ai_response(data_error: "the answer was not valid JSON (x)") }
    assert_match "finish_reason was :truncated", failure_message { assert_ai_structured build_ai_response(finish_reason: :truncated) }
  end

  test "assert_ai_within checks only the limits given" do
    response = build_ai_response(latency: 2.5, usage: { input_tokens: 100, output_tokens: 50 })
    assert_ai_within response, output_tokens: 50, total_tokens: 150, seconds: 3
    assert_ai_within response
    assert_match "Used 50 output tokens (limit 49)", failure_message { assert_ai_within response, output_tokens: 49 }
    assert_match "Used 150 tokens in total (limit 149)", failure_message { assert_ai_within response, total_tokens: 149 }
    assert_match "Took 2.5s (limit 2s)", failure_message { assert_ai_within response, seconds: 2 }
  end

  test "assert_ai_served_by checks the provider, and the model by string or pattern" do
    response = build_ai_response(provider: :openai, model: "gpt-5.6-terra")
    assert_ai_served_by response, provider: :openai
    assert_ai_served_by response, provider: "openai", model: "gpt-5.6-terra"
    assert_ai_served_by response, provider: :openai, model: /\Agpt-5/
    assert_match "Expected provider :anthropic", failure_message { assert_ai_served_by response, provider: :anthropic }
    assert_match "Expected served model", failure_message { assert_ai_served_by response, provider: :openai, model: "gpt-4" }
    assert_match "Expected served model", failure_message { assert_ai_served_by response, provider: :openai, model: /\Aclaude/ }
  end

  test "a custom message replaces the default" do
    assert_equal "my message", failure_message { assert_ai_complete build_ai_response(finish_reason: :truncated), "my message" }
  end

  test "the factory output really is what agent.generate returns" do
    assert_equal ActiveAI::Response.members.sort, ActiveAI::Response.new(**build_ai_response.to_h).members.sort
  end
end
