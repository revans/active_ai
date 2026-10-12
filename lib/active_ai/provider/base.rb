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
    end
  end
end
