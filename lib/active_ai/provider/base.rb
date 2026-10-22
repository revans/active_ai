require "digest"

module ActiveAI
  module Provider
    # Abstract provider base class. Subclasses wrap provider-specific gems.
    # Same pattern as ActiveRecord adapters wrapping database driver gems.
    class Base
      # Hardcoded fallback model list — used when the API is unreachable.
      def self.model_defaults
        []
      end

      # Account-specific catalog. Explicit keys never fall back to shared credentials.
      # Set fallback: false to distinguish discovery failure (nil) from a live list.
      def self.models(api_key: ActiveAI.config.api_key_for(provider_name), refresh: false, fallback: true)
        return fallback ? model_defaults : nil if api_key.to_s.empty?

        catalog = if defined?(Rails) && Rails.respond_to?(:cache) && Rails.cache
          cache_key = "active_ai/models/v2/#{provider_name}/#{Digest::SHA256.hexdigest(api_key)}"
          Rails.cache.fetch(cache_key, expires_in: 24.hours, force: refresh, skip_nil: true) do
            fetch_models(api_key: api_key)
          end
        else
          fetch_models(api_key: api_key)
        end
        catalog || (fallback ? model_defaults : nil)
      end

      # Reject malformed responses instead of offering a partial or invalid catalog.
      def self.model_ids(data)
        return nil unless data.is_a?(Array)
        ids = data.map { |item| item.is_a?(Hash) ? item["id"] : nil }
        return nil unless ids.all? { |id| id.is_a?(String) && id.length.between?(1, 256) && id.match?(/\A[a-zA-Z0-9][a-zA-Z0-9._:\/-]*\z/) }
        ids.uniq.sort
      end
      private_class_method :model_ids

      # Subclasses override to hit the provider's /models endpoint.
      # Returns an array of model ID strings, or nil on failure.
      def self.fetch_models(api_key:)
        nil
      end

      def self.provider_name
        name.demodulize.downcase
      end

      def call(params)
        raise NotImplementedError, "#{self.class}#call is not implemented"
      end

      def stream(params, &block)
        raise NotImplementedError, "#{self.class}#stream is not implemented"
      end

      # Returns tool calls from the last stream response as:
      #   [{ id:, name:, input: }]
      # Empty array when no tools were invoked.
      def last_tool_calls
        []
      end

      # Returns the raw content array of the last assistant turn —
      # used to reconstruct the conversation history in the agentic loop.
      def last_assistant_content
        []
      end

      # Formats the assistant message for the agentic loop history after a tool
      # call turn. Think of it as writing the "model's previous turn" into the
      # conversation before you hand it back to the model with the tool result.
      #
      # Default: Anthropic format — assistant turn uses a content array.
      # Override in providers that expect a different wire shape (e.g. OpenAI).
      def format_assistant_turn(assistant_content, _tool_calls)
        { role: "assistant", content: assistant_content }
      end

      # Returns the messages to append for tool results in the agentic loop
      # history. Think of it as the receipt you hand back: "here is what the
      # tool returned, now continue."
      #
      # Default: Anthropic format — all results bundled in one role:user message.
      # Override in providers that expect individual messages (e.g. OpenAI role:tool).
      def format_tool_result_messages(tool_results)
        [{ role: "user", content: tool_results }]
      end

      PROVIDER_LABELS = { "openai" => "OpenAI", "xai" => "xAI", "anthropic" => "Anthropic" }.freeze
      MAX_PROVIDER_MESSAGE = 600
      # Provider errors sometimes echo a (masked) key: "Incorrect API key provided: sk-proj-****abcd".
      KEY_SHAPED = /\b(?:sk|xai|pk|rk)-[A-Za-z0-9_\-*.]{4,}|Bearer\s+\S+/i

      private

      # Merges the agent's provider_options into the request. A nil value removes a parameter instead.
      def apply_options(params, options)
        Hash(options).each do |key, value|
          value.nil? ? params.delete(key.to_sym) : params[key.to_sym] = value
        end
        params
      end

      def provider_label
        PROVIDER_LABELS.fetch(self.class.provider_name) { self.class.name.demodulize }
      end

      # Turns whatever an SDK raised into an ActiveAI::ProviderError that still says what the provider said.
      #
      # An HTTP error keeps its status and the provider's own explanation. A failure with no HTTP response
      # (timeout, refused connection) is labelled a network error. Only the status and the error body are
      # read: never request headers or the request body, so neither the API key nor the prompt can leak here.
      def provider_error_from(error)
        status, body = http_details(error)
        return network_failure(error) if status.nil? && defined?(Faraday::Error) && error.is_a?(Faraday::Error)
        return ActiveAI::ProviderError.new("#{provider_label}: #{clean_message(error.message)}", cause: error) if status.nil?

        details = error_details(body)
        # The provider's own words first; failing that, whatever the SDK said. Never nothing.
        text = details[:message] || clean_message(error.message)
        ActiveAI::ProviderError.new(
          "#{provider_label}: HTTP #{status}#{error_labels(details)}: #{text}",
          cause: error, status: status.to_i, provider_message: text,
          type: details[:type], code: details[:code], param: details[:param]
        )
      end

      def network_failure(error)
        ActiveAI::ProviderError.new("Network error: #{clean_message(error.message)}", cause: error)
      end

      # Faraday errors carry response[:status]/[:body]; the Anthropic SDK's carry #status and #body.
      def http_details(error)
        if error.respond_to?(:response) && error.response.is_a?(Hash)
          [ error.response[:status], error.response[:body] ]
        elsif error.respond_to?(:status) && error.respond_to?(:body)
          [ error.status, error.body ]
        end
      end

      # OpenAI/xAI: {"error": {"message", "type", "code", "param"}}. Anthropic: {"type": "error", "error": {"type", "message"}}.
      # Some gateways send {"error": "text"}. Anything else is reported as having no details, never dumped raw.
      def error_details(body)
        if body.is_a?(String) && body.lstrip.start_with?("{")
          body = begin
            JSON.parse(body)
          rescue JSON::ParserError
            return salvage_details(body)
          end
        end
        return {} unless body.is_a?(Hash)

        node = body.with_indifferent_access
        error = node[:error]
        fields = error.is_a?(Hash) ? error : node
        message = error.is_a?(String) ? error : fields[:message]
        { message: message.presence && clean_message(message), type: fields[:type].presence, code: fields[:code].presence, param: fields[:param].presence }
      end

      # While streaming, the SDK hands the error body over in pieces and the exception keeps only the first
      # part, so the JSON arrives cut off mid-object (e.g. ends after `"message": "...",`). Strict parsing
      # fails, but any field that arrived whole is still readable.
      def salvage_details(text)
        fields = %i[message type code param].to_h { |key| [ key, quoted_field(text, key) ] }.compact
        fields[:message] = clean_message(fields[:message]) if fields[:message]
        fields
      end

      def quoted_field(text, key)
        raw = text[/"#{key}"\s*:\s*"((?:[^"\\]|\\.)*)"/, 1] or return nil
        JSON.parse(%("#{raw}")).presence
      rescue JSON::ParserError
        raw.presence
      end

      def error_labels(details)
        kind = [ details[:type], details[:code] ].compact.map(&:to_s).uniq.join("/")
        "#{" (#{kind})" if kind.present?}#{" [param: #{details[:param]}]" if details[:param]}"
      end

      def clean_message(text)
        text.to_s.gsub(KEY_SHAPED, "[redacted]").gsub(/[[:cntrl:]]+/, " ").squish.truncate(MAX_PROVIDER_MESSAGE)
      end
    end
  end
end
