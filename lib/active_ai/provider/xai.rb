require_relative "openai"

module ActiveAI
  module Provider
    class XAI < OpenAI
      MODEL_DEFAULTS      = %w[grok-3 grok-3-mini].freeze

      def self.model_defaults
        MODEL_DEFAULTS
      end

      def self.fetch_models(api_key:)
        fetch_openai_compatible_models(
          uri:      URI("https://api.x.ai/v1/models"),
          api_key:  api_key
        )
      end

      # xAI may not accept stream_options: { include_usage: true } — it is an
      # OpenAI-compatible extension that not all providers support. xAI reports
      # usage per-chunk without needing the flag, so we omit it to stay safe.
      def stream(canonical, &block)
        @last_tool_calls        = []
        @last_assistant_content = []
        accumulator = {}

        params = build_params(canonical).merge(
          stream: proc { |chunk, _| handle_chunk(chunk, accumulator, &block) }
          # stream_options intentionally omitted — xAI includes usage per-chunk
        )

        client.chat(parameters: params)
        @last_usage = normalize_usage(accumulator)
        finalize_tool_calls(accumulator)
      rescue ::OpenAI::Error, Faraday::Error => provider_error
        raise provider_error_from(provider_error)
      end

      private

      def build_params(canonical)
        super(canonical)
      end

      def client
        @client ||= begin
          api_key = ActiveAI.config.api_key_for(:xai)
          if api_key.blank?
            raise ActiveAI::ConfigurationError,
              "No API key configured for :xai — set XAI_API_KEY in ENV, " \
              "add it to Rails credentials under active_ai.xai_api_key, or " \
              "register an api_key_resolver in config/initializers/active_ai.rb"
          end
          ::OpenAI::Client.new(access_token: api_key, uri_base: "https://api.x.ai/v1")
        end
      end
    end
  end
end
