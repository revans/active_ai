ActiveAI.configure do |config|
  # Resolve LLM API keys from the database first — keys stored here change without
  # a deployment. Falls through to Rails credentials, then ENV if nil.
  #
  # config.api_key_resolver = ->(provider) { Setting.instance.api_key_for(provider) }

  # Search provider for ActiveAI::Tools::WebSearch (optional — omit if not using web search).
  # Supported: :firecrawl, :brave, :tavily
  #
  # config.search_provider = :firecrawl
  # config.search_api_key  = ENV["FIRECRAWL_API_KEY"]  # omit to read from ENV automatically
end
