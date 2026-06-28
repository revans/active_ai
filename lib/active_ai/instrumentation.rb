module ActiveAI
  # Thread-local caller stack for cross-component instrumentation context.
  #
  # Think of it like a call stack for the AI layer: when an orchestrator calls an agent,
  # which calls a tool, the stack records who called what. Each notification payload
  # reads the top of the stack to answer "who triggered me?"
  #
  # Usage:
  #   ActiveAI::Instrumentation.with_caller(type: :agent, name: "WritingAgent") do
  #     # inside here, current_caller returns { type: :agent, name: "WritingAgent" }
  #   end
  #
  module Instrumentation
    def self.caller_stack
      Thread.current[:active_ai_caller_stack] ||= []
    end

    def self.current_caller
      caller_stack.last
    end

    def self.with_caller(type:, name:)
      caller_stack.push({ type: type, name: name })
      yield
    ensure
      caller_stack.pop
    end
  end
end
