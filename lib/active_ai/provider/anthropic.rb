begin
  require "anthropic"
rescue LoadError
  raise LoadError, "Add `gem 'anthropic'` to your Gemfile to use the Anthropic provider"
end
require "net/http"
require "json"

module ActiveAI
  module Provider
    class Anthropic < Base
      MODEL_DEFAULTS = %w[claude-sonnet-4-6 claude-haiku-4-5-20251001 claude-opus-4-8].freeze

      def self.model_defaults
        MODEL_DEFAULTS
      end

      def self.fetch_models(api_key:)
        uri  = URI("https://api.anthropic.com/v1/models")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl      = true
        http.open_timeout = 5
        http.read_timeout = 10

        request = Net::HTTP::Get.new(uri)
        request["x-api-key"]         = api_key
        request["anthropic-version"] = "2023-06-01"

        response = http.request(request)
        return nil unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body)["data"].map { |model_data| model_data["id"] }.sort
      rescue => error
        Rails.logger.error("ActiveAI::Provider::Anthropic.fetch_models failed: #{error.message}")
        nil
      end

      attr_reader :last_usage, :last_tool_calls, :last_assistant_content

      def call(canonical)
        params   = build_anthropic_params(canonical)
        response = client.messages.create(**params)
        @last_usage             = extract_usage(response)
        @last_tool_calls        = []
        @last_assistant_content = []
        response.content.first.text
      rescue ::Anthropic::Errors::Error => provider_error
        raise ActiveAI::ProviderError.new("Anthropic: #{provider_error.message}", cause: provider_error)
      end

      def stream(canonical, &block)
        @last_usage             = nil
        @last_tool_calls        = []
        @last_assistant_content = []
        params             = build_anthropic_params(canonical)
        message_stream     = client.messages.stream(**params)
        message_stream.text.each { |text| yield text }
        accumulated_message         = message_stream.accumulated_message
        @last_usage             = extract_usage(accumulated_message)
        @last_tool_calls        = extract_tool_calls(accumulated_message)
        @last_assistant_content = extract_assistant_content(accumulated_message)
      rescue ::Anthropic::Errors::Error => provider_error
        raise ActiveAI::ProviderError.new("Anthropic: #{provider_error.message}", cause: provider_error)
      end

      private

      # Translates canonical params into the Anthropic messages.create wire format.
      # Injects cache_control on system blocks and the context message based on cacheable hints.
      def build_anthropic_params(canonical)
        params = {
          model:      canonical[:model],
          max_tokens: canonical[:max_tokens],
          system:     build_system_blocks(canonical),
          messages:   build_messages_with_cache(canonical)
        }
        tools = Array(canonical[:tools])
        params[:tools] = tools if tools.any?
        params
      end

      # Builds the system array: base system block, one block per skill, optional source files block.
      # Each block gets cache_control if that section is declared cacheable.
      # Skills are sent as independent blocks so each can be cached and identified separately.
      def build_system_blocks(canonical)
        cacheable = canonical[:cacheable] || {}
        blocks    = []

        unless canonical[:system].blank?
          system_block = { type: "text", text: canonical[:system] }
          system_block[:cache_control] = { type: "ephemeral" } if cacheable[:system]
          blocks << system_block
        end

        Array(canonical[:skills]).each do |skill|
          next if skill[:content].blank?  # Anthropic rejects text: nil or text: ""
          blocks << { type: "text", text: skill[:content] }
        end

        if canonical[:source_files].any?
          file_text = canonical[:source_files].map { |sf|
            "=== #{sf.name} ===\n#{sf.content}"
          }.join("\n\n")

          sf_block = { type: "text", text: file_text }
          sf_block[:cache_control] = { type: "ephemeral" } if cacheable[:source_files]
          blocks << sf_block
        end

        blocks
      end

      # Returns messages array with cache_control injected at the appropriate points.
      #
      # cache :context — first user message (the stable document body). Caches
      #   everything up to the opening of the conversation.
      # cache :messages — last user message (the current conversation boundary).
      #   Caches all conversation history up to the current turn.
      #
      # Think of each cache_control as a bookmark: Anthropic reuses anything before
      # the bookmark on subsequent requests. Up to 4 bookmarks per request.
      def build_messages_with_cache(canonical)
        cacheable = canonical[:cacheable] || {}
        messages  = canonical[:messages].map(&:dup)

        if cacheable[:context] && messages.first&.fetch(:role, nil) == "user"
          context_text = messages.first[:content].to_s
          messages.first[:content] = [{
            type:          "text",
            text:          context_text,
            cache_control: { type: "ephemeral" }
          }]
        end

        if cacheable[:messages]
          last_user_idx = messages.rindex { |m| m.fetch(:role, nil) == "user" }
          inject_cache_on_message_block(messages, last_user_idx) if last_user_idx
        end

        messages
      end

      # Injects cache_control: { type: "ephemeral" } onto the message at idx.
      # When content is already an Array (expanded by a prior cache injection),
      # adds cache_control to the last block only if not already present —
      # avoids redundant double-injection when :context and :messages target the
      # same message (i.e. single-message conversations).
      def inject_cache_on_message_block(messages, idx)
        content = messages[idx][:content]
        if content.is_a?(Array)
          return if content.last&.key?(:cache_control)
          messages[idx][:content] = content[0..-2] + [content.last.merge(cache_control: { type: "ephemeral" })]
        else
          messages[idx][:content] = [{
            type:          "text",
            text:          content.to_s,
            cache_control: { type: "ephemeral" }
          }]
        end
      end

      def extract_tool_calls(msg)
        return [] unless msg.respond_to?(:content)
        Array(msg.content).filter_map do |block|
          next unless block.respond_to?(:type) && block.type == :tool_use
          { id: block.id, name: block.name, input: parse_tool_input(block.input) }
        end
      end

      def extract_assistant_content(msg)
        return [] unless msg.respond_to?(:content)
        Array(msg.content).map do |block|
          if block.respond_to?(:type) && block.type == :tool_use
            { type: "tool_use", id: block.id, name: block.name, input: parse_tool_input(block.input) }
          elsif block.respond_to?(:text)
            { type: "text", text: block.text }
          else
            block
          end
        end
      end

      # Streaming leaves tool input as a raw JSON string; the SDK only parses it
      # when the tool is registered directly with the Anthropic client (we don't).
      def parse_tool_input(input)
        return input unless input.is_a?(String)
        JSON.parse(input)
      rescue JSON::ParserError
        {}
      end

      def extract_usage(response)
        return nil unless response.respond_to?(:usage) && response.usage
        raw_usage = response.usage
        {
          input_tokens:          raw_usage.input_tokens,
          output_tokens:         raw_usage.output_tokens,
          cache_creation_tokens: safe_field(raw_usage, :cache_creation_input_tokens),
          cache_read_tokens:     safe_field(raw_usage, :cache_read_input_tokens),
          stop_reason:           safe_field(response, :stop_reason),
          provider_request_id:   safe_field(response, :id)
        }
      end

      def safe_field(obj, method)
        obj.respond_to?(method) ? obj.public_send(method) : nil
      end

      def client
        @client ||= begin
          api_key = ActiveAI.config.api_key_for(:anthropic)
          if api_key.blank?
            raise ActiveAI::ConfigurationError,
              "No API key configured for :anthropic — set ANTHROPIC_API_KEY in ENV, " \
              "add it to Rails credentials under active_ai.anthropic_api_key, or " \
              "register an api_key_resolver in config/initializers/active_ai.rb"
          end
          ::Anthropic::Client.new(api_key: api_key)
        end
      end
    end
  end
end
