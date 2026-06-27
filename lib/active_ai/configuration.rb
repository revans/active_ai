module ActiveAI
  # Reads config/ai.yml and exposes a configuration object.
  # Works like ActiveRecord reading database.yml — one config per environment.
  class Configuration
    attr_reader   :provider, :model, :max_tokens
    attr_accessor :api_key_resolver, :search_provider, :search_api_key

    def initialize(provider:, model:, max_tokens: 8096)
      @provider   = provider.to_sym
      @model      = model
      @max_tokens = max_tokens.to_i
    end

    # Returns the API key for the given provider.
    # Priority chain: database (resolver) → Rails credentials → ENV variable.
    # The resolver is a callable registered in config/initializers/active_ai.rb —
    # it lets the app plug in any key source (DB, secrets manager, etc.) without
    # the library knowing which source it is.
    def api_key_for(provider)
      provider = provider.to_s

      if api_key_resolver
        key = api_key_resolver.call(provider)
        return key if key.present?
      end

      key = credentials_key(provider)
      return key if key.present?

      ENV["#{provider.upcase}_API_KEY"]
    end

    # Legacy — returns Anthropic key.
    def api_key
      api_key_for(:anthropic)
    end

    def self.load_from_file(path = nil)
      path ||= Rails.root.join("config", "ai.yml")
      return defaults unless File.exist?(path)

      raw = YAML.load_file(path, aliases: true).with_indifferent_access
      env = raw[Rails.env] || raw["default"] || {}
      new(
        provider:   env[:provider]   || "anthropic",
        model:      env[:model]      || "claude-sonnet-4-6",
        max_tokens: env[:max_tokens] || 8096
      )
    end

    def self.defaults
      new(provider: "anthropic", model: "claude-sonnet-4-6", max_tokens: 8096)
    end

    private

    # Reads from Rails credentials under the active_ai namespace:
    #   credentials.active_ai.anthropic_api_key
    # Returns nil when credentials aren't set up or the key is absent.
    def credentials_key(provider)
      Rails.application.credentials.dig(:active_ai, :"#{provider}_api_key")
    rescue
      nil
    end
  end
end
