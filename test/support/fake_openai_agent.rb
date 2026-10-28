# An agent whose OpenAI client is faked: each provider call replays one entry of `turns`
# ([chunks, error-to-raise-after-them]) and records the messages it was sent.
module FakeOpenAIAgent
  class Lookup < ActiveAI::Tool::Base
    tool_name "lookup"
    description "Looks something up"
    def call(**) = "ship on Friday"
  end

  def self.text_chunks(text) = [ { "id" => "chatcmpl-1", "choices" => [ { "delta" => { "content" => text }, "finish_reason" => nil } ], "usage" => nil } ]
  def self.stop_chunks = [ { "id" => "chatcmpl-1", "choices" => [ { "delta" => {}, "finish_reason" => "stop" } ], "usage" => nil },
                           { "id" => "chatcmpl-1", "choices" => [], "usage" => { "prompt_tokens" => 20, "completion_tokens" => 6 } } ]
  def self.tool_chunks = [
    { "id" => "chatcmpl-0", "choices" => [ { "delta" => { "tool_calls" => [ { "index" => 0, "id" => "call_1", "type" => "function", "function" => { "name" => "lookup", "arguments" => "{}" } } ] }, "finish_reason" => nil } ], "usage" => nil },
    { "id" => "chatcmpl-0", "choices" => [ { "delta" => {}, "finish_reason" => "tool_calls" } ], "usage" => nil },
    { "id" => "chatcmpl-0", "choices" => [], "usage" => { "prompt_tokens" => 10, "completion_tokens" => 5 } } ]

  # A tool call, then an answer: two provider calls.
  def self.tool_then_answer = [ [ tool_chunks, nil ], [ text_chunks("Friday.") + stop_chunks, nil ] ]

  # Returns [agent, sent], where sent collects the canonical messages of each provider call.
  def self.build(turns)
    provider = ActiveAI::Provider::OpenAI.new
    sent     = []
    calls    = 0
    fake     = Object.new
    fake.define_singleton_method(:chat) do |parameters:|
      chunks, failure = turns.fetch(calls)
      calls += 1
      chunks.each { |chunk| parameters[:stream].call(chunk, nil) }
      raise failure if failure
    end
    provider.instance_variable_set(:@client, fake)
    provider.define_singleton_method(:stream) { |canonical, &block| sent << canonical[:messages]; super(canonical, &block) }
    agent = Class.new(WritingAgent) { tools Lookup }.new(system: "s", message: "when do we ship?")
    agent.define_singleton_method(:provider_instance) { provider }
    [ agent, sent ]
  end
end
