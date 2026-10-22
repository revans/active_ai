require "test_helper"
require "json"

# Contract tests against the real provider APIs. They exist because stubbed SDK clients can only
# confirm what we already believe. Two bugs once passed hundreds of green tests: OpenAI had stopped
# accepting `max_tokens`, and while streaming the SDK hands back an error body cut off mid-object.
# Both only show up on the real wire.
#
#   ACTIVE_AI_LIVE=1 OPENAI_API_KEY=... ANTHROPIC_API_KEY=... bundle exec rake test:live
#
# Costs a few cents. ACTIVE_AI_RECORD=1 also rewrites test/fixtures/provider_errors/*.json from the real
# error responses; the offline suite replays those. Models default to cheap ones; override with
# ACTIVE_AI_LIVE_OPENAI_MODEL / ACTIVE_AI_LIVE_ANTHROPIC_MODEL.
module LiveHelper
  FIXTURE_DIR = File.expand_path("../fixtures/provider_errors", __dir__)
  DEFAULT_MODELS = { openai: "gpt-5.6-luna", anthropic: "claude-haiku-5-5" }.freeze
  BAD_KEY = "sk-invalid-contract-test-0123456789abcdef".freeze

  def self.live? = ENV["ACTIVE_AI_LIVE"] == "1"
  def self.recording? = ENV["ACTIVE_AI_RECORD"] == "1"

  def model_for(provider) = ENV["ACTIVE_AI_LIVE_#{provider.to_s.upcase}_MODEL"].presence || DEFAULT_MODELS.fetch(provider)

  def provider_class(provider) = ActiveAI::Provider.const_get(provider == :openai ? "OpenAI" : "Anthropic")

  def skip_unless_live!(provider)
    skip "set ACTIVE_AI_LIVE=1 to run contract tests against the real APIs" unless LiveHelper.live?
    skip "no #{provider.to_s.upcase}_API_KEY in the environment" if ActiveAI.config.api_key_for(provider).blank?
  end

  def canonical(model:, message: "Reply with exactly one word: ok", **extra)
    { model: model, max_tokens: 400, system: "You reply tersely.", skills: [], source_files: [], cacheable: {},
      messages: [ { role: "user", content: message } ] }.merge(extra)
  end

  # A provider whose SDK client uses a key that cannot be valid.
  def provider_with_bad_key(provider)
    instance = provider_class(provider).new
    client = provider == :openai ? ::OpenAI::Client.new(access_token: BAD_KEY) : ::Anthropic::Client.new(api_key: BAD_KEY)
    instance.instance_variable_set(:@client, client)
    instance
  end

  # What the SDK actually received, for the fixture: HTTP status and body exactly as handed to the exception.
  def raw_http(error)
    cause = error.cause
    if cause.respond_to?(:response) && cause.response.is_a?(Hash)
      [ cause.response[:status], cause.response[:body] ]
    else
      [ cause.status, cause.body ]
    end
  end

  def record_fixture(provider, scenario, error, expect_contains: nil)
    return unless LiveHelper.recording?
    status, body = raw_http(error)
    FileUtils.mkdir_p(FIXTURE_DIR)
    File.write(File.join(FIXTURE_DIR, "#{provider}_#{scenario}.json"), JSON.pretty_generate(
      provider: provider, scenario: scenario, status: status, body: body, sdk_message: error.cause.message,
      expect_contains: expect_contains, recorded_on: Date.current.iso8601
    ))
  end
end
