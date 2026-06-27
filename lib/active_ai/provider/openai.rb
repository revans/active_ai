begin
  require "openai"
rescue LoadError
  raise LoadError, "Add `gem 'ruby-openai'` to your Gemfile to use the OpenAI provider"
end
require "net/http"
require "json"

module ActiveAI
  module Provider
    class OpenAI < Base
      MODEL_DEFAULTS       = %w[gpt-4.1 gpt-4.1-mini gpt-4.1-nano gpt-4o gpt-4o-mini o4-mini o3-mini o3].freeze
      CHAT_MODEL_PREFIXES  = %w[gpt-4 gpt-4o gpt-4.1 o1 o3 o4].freeze
      CHAT_MODEL_EXCLUSIONS = %w[-transcribe -tts -search-preview -moderation gpt-image].freeze

      def self.model_defaults
        MODEL_DEFAULTS
      end

      def self.fetch_models(api_key:)
        fetch_openai_compatible_models(
          uri:     URI("https://api.openai.com/v1/models"),
          api_key: api_key,
          prefixes: CHAT_MODEL_PREFIXES
        )
      end

      def self.fetch_openai_compatible_models(uri:, api_key:, prefixes:)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl      = true
        http.open_timeout = 5
        http.read_timeout = 10

        request = Net::HTTP::Get.new(uri)
        request["Authorization"] = "Bearer #{api_key}"

        response = http.request(request)
        return nil unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body)["data"]
          .map    { |model_data| model_data["id"] }
          .select { |id| prefixes.any? { |prefix| id.start_with?(prefix) } }
          .reject { |id| CHAT_MODEL_EXCLUSIONS.any? { |exclusion| id.include?(exclusion) } }
          .sort
      rescue => fetch_error
        Rails.logger.error("#{self}.fetch_models failed: #{fetch_error.message}")
        nil
      end

      attr_reader :last_usage

      def last_tool_calls;        @last_tool_calls        || []; end
      def last_assistant_content; @last_assistant_content || []; end

      def call(canonical)
        @last_tool_calls        = []
        @last_assistant_content = []
        response    = client.chat(parameters: build_params(canonical))
        @last_usage = extract_usage_from_response(response)
        response.dig("choices", 0, "message", "content")
      rescue ::OpenAI::Error => openai_error
        raise ActiveAI::ProviderError.new("OpenAI: #{openai_error.message}", cause: openai_error)
      rescue Faraday::Error => faraday_error
        raise ActiveAI::ProviderError.new("Network error: #{faraday_error.message}", cause: faraday_error)
      end

      def stream(canonical, &block)
        @last_tool_calls        = []
        @last_assistant_content = []
        accumulator = {}

        params = build_params(canonical).merge(
          stream:         proc { |chunk, _| handle_chunk(chunk, accumulator, &block) },
          stream_options: { include_usage: true }
        )

        client.chat(parameters: params)
        @last_usage = normalize_usage(accumulator)
        finalize_tool_calls(accumulator)
      rescue ::OpenAI::Error => openai_error
        raise ActiveAI::ProviderError.new("OpenAI: #{openai_error.message}", cause: openai_error)
      rescue Faraday::Error => faraday_error
        raise ActiveAI::ProviderError.new("Network error: #{faraday_error.message}", cause: faraday_error)
      end

      # Formats the OpenAI assistant turn for the agentic loop history.
      # OpenAI requires: { role: "assistant", content: nil, tool_calls: [...] }
      # Anthropic uses:  { role: "assistant", content: [{ type: "tool_use", ... }] }
      # Sending Anthropic format to OpenAI → 400 Bad Request.
      def format_assistant_turn(_assistant_content, tool_calls)
        openai_calls = tool_calls.map { |tc|
          {
            "id"       => tc[:id],
            "type"     => "function",
            "function" => { "name" => tc[:name], "arguments" => tc[:input].to_json }
          }
        }
        { role: "assistant", content: nil, tool_calls: openai_calls }
      end

      # Formats tool results as individual role:tool messages for OpenAI.
      # OpenAI wants one message per result; Anthropic bundles them in role:user.
      def format_tool_result_messages(tool_results)
        tool_results.map { |tr|
          { role: "tool", tool_call_id: tr[:tool_use_id], content: tr[:content] }
        }
      end

      private

      def build_params(canonical)
        # Combine system prompt + skills + source files into a single system message.
        # OpenAI doesn't support separate blocks with cache_control — cacheable hints are ignored.
        parts = [canonical[:system].to_s.presence]

        Array(canonical[:skills]).each { |skill| parts << skill[:content] }

        if canonical[:source_files].any?
          file_text = canonical[:source_files].map { |source_file|
            "=== #{source_file.name} ===\n#{source_file.content}"
          }.join("\n\n")
          parts << file_text
        end

        system_content = parts.compact.join("\n\n")

        messages = []
        messages << { role: "system", content: system_content } if system_content.present?
        messages.concat(canonical[:messages])

        params = {
          model:      canonical[:model],
          max_tokens: canonical[:max_tokens],
          messages:   messages
        }

        # Convert Anthropic-format tool definitions to OpenAI format.
        # Anthropic uses `input_schema:`; OpenAI wraps each tool in
        # { type: "function", function: { name:, description:, parameters: } }.
        tools = Array(canonical[:tools])
        if tools.any?
          params[:tools] = tools.map { |t|
            {
              type:     "function",
              function: {
                name:        t[:name],
                description: t[:description],
                parameters:  t[:input_schema] || { type: "object", properties: {}, required: [] }
              }
            }
          }
        end

        params
      end

      # stop_reason and usage arrive on DIFFERENT chunks in OpenAI streaming:
      #   - Mid-stream chunks:   choices[0].delta.content = text, usage = null
      #   - Penultimate chunk:   choices[0].finish_reason = "stop"/"length", usage = null
      #   - Final (usage) chunk: choices = [], usage = { prompt_tokens:, completion_tokens:, ... }
      #   - Error chunk:         { "error" => { "message" => "...", "type" => "...", "code" => "..." } }
      #
      # Error chunks arrive when the API returns an HTTP error (401, 429, 500) formatted as
      # an SSE data event. Without the guard below, handle_chunk silently ignores them:
      # choices is [], nothing is yielded, accumulator stays empty, complete returns "".
      #
      # We accumulate both into the same hash as they arrive.
      def handle_chunk(chunk, accumulator, &block)
        if (error = chunk["error"])
          code    = error["code"] || error["type"] || "unknown"
          message = error["message"] || "Unknown provider error"
          raise ActiveAI::ProviderError, "OpenAI error (#{code}): #{message}"
        end

        choices = chunk["choices"] || []

        content = choices.dig(0, "delta", "content")
        yield content if content.present?

        # Accumulate tool_call deltas — OpenAI sends the tool call across multiple
        # chunks, like a jigsaw puzzle: first chunk names the tool, subsequent
        # chunks deliver argument fragments that must be concatenated.
        tool_calls_delta = choices.dig(0, "delta", "tool_calls")
        if tool_calls_delta
          accumulator["tool_calls"] ||= {}
          tool_calls_delta.each do |delta|
            idx = delta["index"] || 0
            tc  = accumulator["tool_calls"][idx] ||= {
              "id"       => nil,
              "type"     => "function",
              "function" => { "name" => nil, "arguments" => "" }
            }
            tc["id"]                    = delta["id"]                     if delta["id"]
            tc["type"]                  = delta["type"]                   if delta["type"]
            tc["function"]["name"]      = delta.dig("function", "name")   if delta.dig("function", "name")
            tc["function"]["arguments"] += delta.dig("function", "arguments").to_s
          end
        end

        finish_reason = choices.dig(0, "finish_reason")
        accumulator["finish_reason"] = finish_reason if finish_reason

        if chunk["usage"]
          accumulator.merge!(chunk["usage"])
          accumulator["id"] = chunk["id"]
        end
      end

      # Populates @last_tool_calls and @last_assistant_content from the accumulator
      # after streaming completes. Arguments arrive as a JSON string and are parsed
      # here so callers always get a Hash, never a raw JSON string.
      def finalize_tool_calls(accumulator)
        raw_calls = accumulator["tool_calls"]
        if raw_calls&.any?
          tool_calls = raw_calls.sort_by { |idx, _| idx }.map { |_, tc| tc }
          @last_tool_calls = tool_calls.map { |tc|
            {
              id:    tc["id"],
              name:  tc.dig("function", "name"),
              input: begin
                JSON.parse(tc.dig("function", "arguments") || "{}")
              rescue JSON::ParserError
                {}
              end
            }
          }
          @last_assistant_content = @last_tool_calls.dup
        else
          @last_tool_calls        = []
          @last_assistant_content = []
        end
      end

      def extract_usage_from_response(response)
        raw_usage = response["usage"] || {}
        normalize_usage(raw_usage.merge(
          "finish_reason" => response.dig("choices", 0, "finish_reason"),
          "id"            => response["id"]
        ))
      end

      def normalize_usage(raw)
        return nil if raw.empty?
        {
          input_tokens:          raw["prompt_tokens"].to_i,
          output_tokens:         raw["completion_tokens"].to_i,
          cache_creation_tokens: 0,
          cache_read_tokens:     raw.dig("prompt_tokens_details", "cached_tokens").to_i,
          stop_reason:           raw["finish_reason"],
          provider_request_id:   raw["id"]
        }
      end

      def client
        @client ||= begin
          api_key = ActiveAI.config.api_key_for(:openai)
          if api_key.blank?
            raise ActiveAI::ConfigurationError,
              "No API key configured for :openai — set OPENAI_API_KEY in ENV, " \
              "add it to Rails credentials under active_ai.openai_api_key, or " \
              "register an api_key_resolver in config/initializers/active_ai.rb"
          end
          ::OpenAI::Client.new(access_token: api_key, **client_options)
        end
      end

      def client_options
        {}
      end
    end
  end
end
