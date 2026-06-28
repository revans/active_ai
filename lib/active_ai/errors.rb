module ActiveAI
  class Error < StandardError; end

  # Raised when a provider gem raises — wraps provider-specific errors so callers
  # don't need to rescue Anthropic::Error, OpenAI::Error, etc. separately.
  class ProviderError < Error
    attr_reader :cause

    def initialize(msg = nil, cause: nil)
      super(msg)
      @cause = cause
    end
  end

  class ConfigurationError < Error; end
  class MissingPromptError < Error; end

  # Raised when the agentic tool loop exceeds MAX_TOOL_ITERATIONS.
  # This prevents an infinite loop when a model keeps requesting tool calls
  # without ever producing a final text response.
  # Increase ActiveAI::Agent::Base::MAX_TOOL_ITERATIONS if an agent legitimately needs more turns.
  class ToolLoopError < Error; end

  module Tools
    # Raised when a built-in tool is used but its required configuration is absent.
    # Callers provide the full message: raise ActiveAI::Tools::NotConfiguredError, "WebSearch requires..."
    class NotConfiguredError < Error; end
  end
end
