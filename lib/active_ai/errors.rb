module ActiveAI
  class Error < StandardError; end

  # Raised when a provider gem raises — wraps provider-specific errors so callers
  # don't need to rescue Anthropic::Error, OpenAI::Error, etc. separately.
  #
  # For an HTTP error the provider's own explanation is kept, never reduced to "status 400":
  #
  #   error.message           # => "OpenAI: HTTP 400 (invalid_request_error/unsupported_parameter) [param: max_tokens]: Unsupported ..."
  #   error.status            # => 400   (nil when no HTTP response came back: timeout, refused connection)
  #   error.provider_message  # => "Unsupported parameter: ..." (the provider's text alone, key-redacted and truncated)
  #   error.type / code / param
  #
  # The original exception is still available as `cause`.
  class ProviderError < Error
    attr_reader :cause, :status, :provider_message, :type, :code, :param

    def initialize(msg = nil, cause: nil, status: nil, provider_message: nil, type: nil, code: nil, param: nil)
      super(msg)
      @cause = cause
      @status = status
      @provider_message = provider_message
      @type = type
      @code = code
      @param = param
    end

    def network? = status.nil?
    def rate_limited? = status == 429
    def authentication_failed? = [ 401, 403 ].include?(status)

    # Worth trying again later: throttled, a provider-side failure, or no response at all.
    def retryable? = network? || rate_limited? || status.to_i >= 500
  end

  class ConfigurationError < Error; end

  # Raised by Agent#complete_structured when the model's answer is not the JSON it was asked for.
  # The raw text is kept so the caller can log or show it.
  class StructuredOutputError < Error
    attr_reader :raw

    def initialize(msg = nil, raw: nil)
      super(msg)
      @raw = raw
    end
  end
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
