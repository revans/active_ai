module ActiveAI
  module Tools
    module SearchAdapter
      class Base
        # Subclasses must implement:
        #   ENV_KEY — the environment variable name for the API key (e.g. "FIRECRAWL_API_KEY")
        #   search(query) — returns a formatted String ready for the LLM

        def search(query)
          raise NotImplementedError, "#{self.class}#search is not implemented"
        end

        private

        # Prefers the explicit config value; falls back to the provider's ENV variable.
        # This means config.search_api_key is optional — the ENV var works on its own.
        def api_key
          ActiveAI.config.search_api_key.presence || ENV[self.class::ENV_KEY]
        end

        def require_api_key!
          return if api_key.present?
          raise ActiveAI::Tools::NotConfiguredError,
                "#{self.class.name} requires #{self.class::ENV_KEY} in ENV or config.search_api_key"
        end

        def format_results(results)
          return "No results found." if results.empty?
          results.map { |r| "## #{r[:title]}\n#{r[:url]}\n#{r[:body]}" }.join("\n\n---\n\n")
        end
      end
    end
  end
end
