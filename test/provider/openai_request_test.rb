require "test_helper"

# What actually goes over the wire. OpenAI's current models reject `max_tokens` outright
# ("Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead.").
class OpenAIRequestTest < ActiveSupport::TestCase
  def canonical(max_tokens: 321)
    { model: "m", max_tokens: max_tokens, system: "s", skills: [], source_files: [], messages: [ { role: "user", content: "hi" } ], cacheable: {} }
  end

  # Returns the parameters the provider handed to client.chat.
  def sent_by(provider_class, method: :call, **canonical_options)
    sent = nil
    provider = provider_class.new
    client = Object.new
    client.define_singleton_method(:chat) do |parameters:|
      sent = parameters
      { "choices" => [ { "message" => { "content" => "ok" } } ], "usage" => {} }
    end
    provider.instance_variable_set(:@client, client)
    method == :call ? provider.call(canonical(**canonical_options)) : provider.stream(canonical(**canonical_options)) { }
    sent
  end

  test "OpenAI sends max_completion_tokens and never max_tokens" do
    sent = sent_by(ActiveAI::Provider::OpenAI)
    assert_equal 321, sent[:max_completion_tokens]
    refute sent.key?(:max_tokens)
  end

  test "streaming sends it too" do
    sent = sent_by(ActiveAI::Provider::OpenAI, method: :stream)
    assert_equal 321, sent[:max_completion_tokens]
    refute sent.key?(:max_tokens)
  end

  test "xAI keeps max_tokens, which its API still expects" do
    %i[call stream].each do |method|
      sent = sent_by(ActiveAI::Provider::XAI, method: method)
      assert_equal 321, sent[:max_tokens]
      refute sent.key?(:max_completion_tokens)
    end
  end

  test "no limit set means no limit parameter is sent" do
    sent = sent_by(ActiveAI::Provider::OpenAI, max_tokens: nil)
    refute sent.key?(:max_completion_tokens)
    refute sent.key?(:max_tokens)
  end

  test "the rest of the request is unchanged" do
    sent = sent_by(ActiveAI::Provider::OpenAI)
    assert_equal "m", sent[:model]
    assert_equal [ { role: "system", content: "s" }, { role: "user", content: "hi" } ], sent[:messages]
  end
end
