require "test_helper"

# max_tokens in the agent DSL: a positive Integer, or :unlimited.
class MaxTokensTest < ActiveSupport::TestCase
  Info = Struct.new(:max_tokens)
  Block = Struct.new(:type, :text)
  Usage = Struct.new(:input_tokens, :output_tokens)
  AMessage = Struct.new(:content, :stop_reason, :usage, :id, :model)

  setup { ActiveAI::Provider::Anthropic::MAX_OUTPUT_TOKENS.clear }

  def agent_class(&block) = Class.new(WritingAgent, &block)
  def limit_of(klass) = klass.new(system: "s", message: "hi").to_canonical_params[:max_tokens]

  def canonical(max_tokens)
    { model: "m", max_tokens: max_tokens, system: "s", skills: [], source_files: [], messages: [ { role: "user", content: "hi" } ], cacheable: {} }
  end

  # ── the validator ────────────────────────────────────────────────────────────

  test "an Integer, :unlimited and \"unlimited\" are valid, and a numeric string is tolerated" do
    assert_equal 700, ActiveAI.token_limit(700)
    assert_equal :unlimited, ActiveAI.token_limit(:unlimited)
    assert_equal :unlimited, ActiveAI.token_limit("unlimited")
    assert_equal :unlimited, ActiveAI.token_limit(" Unlimited ")
    assert_equal 8096, ActiveAI.token_limit("8096")
  end

  test "anything else is refused with a message that says what is allowed" do
    [ 0, -5, 1.5, nil, "abc", :forever, [], "0", true ].each do |bad|
      error = assert_raises(ArgumentError, bad.inspect) { ActiveAI.token_limit(bad) }
      assert_match "positive Integer or :unlimited", error.message
    end
  end

  # ── the DSL ──────────────────────────────────────────────────────────────────

  test "max_tokens sets the limit, independent of any model" do
    klass = agent_class { max_tokens 700 }
    assert_equal 700, limit_of(klass)
    assert_nil klass._model_config, "no model had to be pinned"
  end

  test "max_tokens :unlimited" do
    assert_equal :unlimited, limit_of(agent_class { max_tokens :unlimited })
  end

  test "a bad limit is refused where it is declared" do
    assert_raises(ArgumentError) { agent_class { max_tokens 0 } }
    assert_raises(ArgumentError) { agent_class { max_tokens "lots" } }
    assert_raises(ArgumentError) { agent_class { model "x", max_tokens: -1 } }
  end

  test "precedence: the agent's max_tokens, then model max_tokens:, then ai.yml" do
    assert_equal ActiveAI.config.max_tokens, limit_of(agent_class)
    assert_equal 500, limit_of(agent_class { model "x", max_tokens: 500 })
    assert_equal 700, limit_of(agent_class { model "x", max_tokens: 500; max_tokens 700 })
    assert_equal :unlimited, limit_of(agent_class { model "x", max_tokens: :unlimited })
  end

  test "a subclass inherits the limit and can replace it" do
    parent = agent_class { max_tokens 700 }
    assert_equal 700, limit_of(Class.new(parent))
    assert_equal 900, limit_of(Class.new(parent) { max_tokens 900 })
    assert_equal 700, limit_of(parent)
  end

  test "resolved_max_tokens is public, like resolved_model" do
    assert_equal 700, agent_class { max_tokens 700 }.new(system: "s", message: "hi").resolved_max_tokens
  end

  test "ai.yml can say unlimited" do
    assert_equal :unlimited, ActiveAI::Configuration.new(provider: "openai", model: "m", max_tokens: "unlimited").max_tokens
    assert_equal 4096, ActiveAI::Configuration.new(provider: "openai", model: "m", max_tokens: 4096).max_tokens
    assert_raises(ArgumentError) { ActiveAI::Configuration.new(provider: "openai", model: "m", max_tokens: 0) }
  end

  # ── OpenAI and xAI: omit the parameter ───────────────────────────────────────

  def openai_sent(provider_class, max_tokens)
    sent = nil
    client = Object.new
    client.define_singleton_method(:chat) { |parameters:| sent = parameters; { "choices" => [ { "message" => { "content" => "ok" } } ], "usage" => {} } }
    provider = provider_class.new
    provider.instance_variable_set(:@client, client)
    provider.call(canonical(max_tokens))
    sent
  end

  test "OpenAI sends the limit as max_completion_tokens, and nothing at all for :unlimited" do
    assert_equal 700, openai_sent(ActiveAI::Provider::OpenAI, 700)[:max_completion_tokens]
    sent = openai_sent(ActiveAI::Provider::OpenAI, :unlimited)
    assert_not sent.key?(:max_completion_tokens)
    assert_not sent.key?(:max_tokens)
  end

  test "xAI sends max_tokens, and nothing at all for :unlimited" do
    assert_equal 700, openai_sent(ActiveAI::Provider::XAI, 700)[:max_tokens]
    sent = openai_sent(ActiveAI::Provider::XAI, :unlimited)
    assert_not sent.key?(:max_tokens)
    assert_not sent.key?(:max_completion_tokens)
  end

  # ── Anthropic: must send one, so send the model's own maximum ────────────────

  def anthropic_provider(max_output: 128_000, lookup_fails: false)
    sent = []
    lookups = []
    message = AMessage.new([ Block.new(:text, "ok") ], "end_turn", Usage.new(1, 1), "m1", "claude-x")
    stream = Object.new
    stream.define_singleton_method(:text) { [ "ok" ].each }
    stream.define_singleton_method(:accumulated_message) { message }
    messages = Object.new
    messages.define_singleton_method(:stream) { |**params| sent << params; stream }
    models = Object.new
    models.define_singleton_method(:retrieve) do |name|
      lookups << name
      raise StandardError, "models API down" if lookup_fails
      Info.new(max_output)
    end
    client = Object.new
    client.define_singleton_method(:messages) { messages }
    client.define_singleton_method(:models) { models }
    provider = ActiveAI::Provider::Anthropic.new
    provider.instance_variable_set(:@client, client)
    [ provider, sent, lookups ]
  end

  test "Anthropic passes an Integer limit straight through, with no lookup" do
    provider, sent, lookups = anthropic_provider
    provider.stream(canonical(700)) { }
    assert_equal 700, sent.last[:max_tokens]
    assert_empty lookups
  end

  test "Anthropic's :unlimited sends the model's own maximum, looked up from its models API" do
    provider, sent, lookups = anthropic_provider(max_output: 128_000)
    provider.stream(canonical(:unlimited)) { }
    assert_equal 128_000, sent.last[:max_tokens]
    assert_equal [ "m" ], lookups
  end

  test "the lookup is remembered per model, so it happens once" do
    provider, _sent, lookups = anthropic_provider
    2.times { provider.stream(canonical(:unlimited)) { } }
    assert_equal 1, lookups.size
  end

  test "a failed lookup falls back to a conservative limit and is retried next time" do
    provider, sent, lookups = anthropic_provider(lookup_fails: true)
    2.times { provider.stream(canonical(:unlimited)) { } }
    assert_equal [ ActiveAI::Provider::Anthropic::FALLBACK_MAX_OUTPUT_TOKENS ] * 2, sent.map { |params| params[:max_tokens] }
    assert_equal 2, lookups.size, "a failure must not be cached"
  end

  test "a missing or zero maximum from the API also falls back" do
    provider, sent, _lookups = anthropic_provider(max_output: 0)
    provider.stream(canonical(:unlimited)) { }
    assert_equal ActiveAI::Provider::Anthropic::FALLBACK_MAX_OUTPUT_TOKENS, sent.last[:max_tokens]
  end

  test "end to end: an agent's max_tokens reaches the provider request" do
    fake, sent, _lookups = anthropic_provider(max_output: 64_000)
    klass = agent_class { provider :anthropic; max_tokens :unlimited }
    agent = klass.new(system: "s", message: "hi")
    agent.define_singleton_method(:provider_instance) { fake }
    agent.complete
    assert_equal 64_000, sent.last[:max_tokens]

    bounded = agent_class { provider :anthropic; max_tokens 700 }.new(system: "s", message: "hi")
    bounded.define_singleton_method(:provider_instance) { fake }
    bounded.complete
    assert_equal 700, sent.last[:max_tokens]
  end
end
