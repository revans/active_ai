module ActiveAI
  module Tools
    # Factory for search provider adapters. Mirrors how ActiveAI::Provider resolves
    # Anthropic vs OpenAI — the tool delegates to the right adapter, callers never
    # know which HTTP API is underneath.
    #
    #   ActiveAI.configure { |c| c.search_provider = :firecrawl }
    #   ActiveAI::Tools::SearchAdapter.for(:firecrawl)  # => Firecrawl instance
    module SearchAdapter
      PROVIDERS = %i[firecrawl brave tavily].freeze

      def self.for(provider)
        raise ActiveAI::Tools::NotConfiguredError,
              "WebSearch requires config.search_provider (#{PROVIDERS.map(&:inspect).join(", ")})" if provider.nil?

        case provider.to_sym
        when :firecrawl then Firecrawl.new
        when :brave     then Brave.new
        when :tavily    then Tavily.new
        else
          raise ActiveAI::ConfigurationError,
                "Unknown search provider: #{provider.inspect}. Use #{PROVIDERS.map(&:inspect).join(", ")}."
        end
      end
    end
  end
end
