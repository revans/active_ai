module ActiveAI
  # Include in any model that owns API credentials for providers or tools.
  #
  #   class Setting < ApplicationRecord
  #     include ActiveAI::HasCredentials
  #   end
  #
  #   Setting.instance.api_key_for("anthropic")                    # => "sk-ant-..."
  #   Setting.instance.api_key_for("firecrawl", category: "tool")  # => "fc-..."
  #   Setting.instance.model_options_for("openai")                 # => ["gpt-4.1", ...]
  #
  module HasCredentials
    extend ActiveSupport::Concern

    included do
      has_many :ai_credentials,
               class_name:  "ActiveAI::Credential",
               as:          :owner,
               dependent:   :destroy
    end

    # Returns the stored API key for a named service.
    # Defaults to category "provider" so the existing resolver lambda needs no change.
    def api_key_for(name, category: "provider")
      ai_credentials.find_by(name: name.to_s, category: category.to_s)&.api_key
    end

    def configured_providers
      ai_credentials.providers.pluck(:name)
    end

    def configured_tools
      ai_credentials.tools.pluck(:name)
    end

    # Returns the live model list for a provider from Rails.cache.
    # Falls back to the provider class's built-in MODEL_DEFAULTS on any failure.
    def model_options_for(provider)
      ActiveAI.provider_class_for(provider).models
    rescue ActiveAI::ConfigurationError
      []
    end
  end
end
