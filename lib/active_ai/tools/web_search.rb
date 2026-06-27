module ActiveAI
  module Tools
    # Searches the web by delegating to the configured search adapter.
    # Configure once in config/initializers/active_ai.rb:
    #
    #   config.search_provider = :firecrawl  # :firecrawl, :brave, or :tavily
    #   config.search_api_key  = ENV["FIRECRAWL_API_KEY"]  # or omit — reads from ENV automatically
    class WebSearch < ActiveAI::Tool::Base
      tool_name "web_search"
      description "Search the web for current information, news, or research on any topic."

      param :query, type: :string, description: "The search query"

      def call(query:)
        adapter.search(query)
      end

      private

      def adapter
        ActiveAI::Tools::SearchAdapter.for(ActiveAI.config.search_provider)
      end
    end
  end
end
