require "test_helper"

# Replays real provider error responses (recorded by test/live with ACTIVE_AI_RECORD=1) through the
# provider error translation. The fakes in provider_errors_test.rb show what we think providers send;
# these are what they actually sent, including the body cut off mid-object while streaming.
class RecordedErrorsTest < ActiveSupport::TestCase
  FIXTURES = Dir[File.expand_path("../fixtures/provider_errors/*.json", __dir__)].sort

  test "there are recorded fixtures to replay" do
    assert_operator FIXTURES.size, :>=, 6, "run `ACTIVE_AI_LIVE=1 ACTIVE_AI_RECORD=1 bundle exec rake test:live` to record them"
  end

  FIXTURES.each do |path|
    fixture = JSON.parse(File.read(path))
    name = File.basename(path, ".json")

    test "#{name}: the real response is translated, with the provider's reason" do
      error = translate(fixture)

      assert_equal fixture["status"], error.status
      assert_predicate error.provider_message, :present?, "no provider message from #{fixture["body"].inspect[0, 120]}"
      assert_match(/\A(OpenAI|Anthropic): HTTP #{fixture["status"]}/, error.message)
      assert_includes error.message, fixture["expect_contains"] if fixture["expect_contains"]
      refute_match(/sk-[A-Za-z0-9_-]{8,}/, error.message, "a key-shaped string leaked into the message")
    end
  end

  private

  def translate(fixture)
    provider_class, sdk_error = if fixture["provider"] == "openai"
      [ ActiveAI::Provider::OpenAI, Faraday::ClientError.new(fixture["sdk_message"], { status: fixture["status"], body: fixture["body"] }) ]
    else
      [ ActiveAI::Provider::Anthropic, Anthropic::Errors::APIStatusError.for(
        url: URI("https://api.anthropic.com/v1/messages"), status: fixture["status"], headers: {}, request: nil, response: nil,
        body: JSON.parse(fixture["body"].to_json, symbolize_names: true), message: fixture["sdk_message"]
      ) ]
    end

    provider = provider_class.new
    client = Object.new
    chat = ->(**) { raise sdk_error }
    client.define_singleton_method(:chat, &chat)
    messages = Object.new
    messages.define_singleton_method(:create, &chat)
    messages.define_singleton_method(:stream, &chat)
    client.define_singleton_method(:messages) { messages }
    provider.instance_variable_set(:@client, client)

    assert_raises(ActiveAI::ProviderError) do
      provider.call(model: "m", max_tokens: 10, system: "s", skills: [], source_files: [], messages: [ { role: "user", content: "hi" } ], cacheable: {})
    end
  end
end
