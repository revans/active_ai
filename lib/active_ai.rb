# ActiveAI — Rails-first AI conversation library.
# Analogous to ActionMailer for email or ActiveJob for background tasks.
#
#   ActiveAI::Agent::Base   ←→  ActionMailer::Base
#   ActiveAI::Provider      ←→  ActionMailer delivery method
#   ActiveAI.config         ←→  Rails.application.config.action_mailer
#   config/ai.yml           ←→  config/database.yml
#
require "active_support/concern"
require "active_support/core_ext/class/attribute"

# Registry must be available before any sub-files (tools, etc.) are loaded
# because they call description() at class-body evaluation time, which registers.
module ActiveAI
  @registry = {}

  class << self
    def registry         = @registry
    def register(klass)  = @registry[klass.name] = klass
  end
end

require "active_ai/version"
require "active_ai/errors"
require "active_ai/configuration"
require "active_ai/concerns/describable"
require "active_ai/instrumentation"
require "active_ai/skill/base"
require "active_ai/tool/base"
require "active_ai/tools/search_adapter/base"
require "active_ai/tools/search_adapter/firecrawl"
require "active_ai/tools/search_adapter/brave"
require "active_ai/tools/search_adapter/tavily"
require "active_ai/tools/search_adapter"
require "active_ai/tools/web_search"
require "active_ai/tools/web_page_reader"
require "active_ai/provider/base"
require "active_ai/provider/anthropic"
require "active_ai/provider/openai"
require "active_ai/provider/xai"
require "active_ai/agent/base"
require "active_ai/promptable"
require "active_ai/orchestratable"
require "active_ai/concerns/instrumentable"
require "active_ai/workflow/base"
require "active_ai/orchestrator/base"
require "active_ai/concerns/streamable"
require "active_ai/prompt_render_context"
require "active_ai/prompt_resolver"
require "active_ai/memory/base"
require "active_ai/memory/vector_store/base"
require "active_ai/memory/vector_store/pgvector"
require "active_ai/memory/store"
require "active_ai/memory/formatter"
require "active_ai/test_helper" if defined?(ActiveSupport::TestCase)
if defined?(Rails::Railtie)
  require "active_ai/application"
  require "active_ai/credential"
  require "active_ai/has_credentials"
  require "active_ai/log_subscriber"
  require "active_ai/railtie"
end

module ActiveAI
  # Maps vector store name strings to their class names.
  VECTOR_STORE_CLASSES = {
    "pgvector" => "ActiveAI::Memory::VectorStore::Pgvector"
  }

  # Maps provider name strings to their class names. Not frozen — register_provider mutates it.
  PROVIDER_CLASSES = {
    "anthropic" => "ActiveAI::Provider::Anthropic",
    "openai"    => "ActiveAI::Provider::OpenAI",
    "xai"       => "ActiveAI::Provider::XAI"
  }

  class << self
    def config
      @config ||= Configuration.load_from_file
    end

    # Global registry of classes that declared a description. Keyed by class name.
    # Classes self-register by calling the description() DSL.
    def registry
      @registry ||= {}
    end

    def register(klass)
      registry[klass.name] = klass
    end

    # All registered agent classes (ActiveAI::Agent::Base descendants, excluding orchestrators).
    def agents
      registry.values.select { |k| k < ActiveAI::Agent::Base && !(k < ActiveAI::Orchestrator::Base) }
    end

    # All registered workflow classes (ActiveAI::Workflow::Base descendants).
    def workflows
      registry.values.select { |k| k < ActiveAI::Workflow::Base }
    end

    # All registered tool classes (ActiveAI::Tool::Base descendants).
    def tools
      registry.values.select { |k| k < ActiveAI::Tool::Base }
    end

    # All registered skill classes (ActiveAI::Skill::Base descendants).
    def skills
      registry.values.select { |k| k < ActiveAI::Skill::Base }
    end

    # Works like Rails.application.config — yields the active config object so
    # initializers can set the api_key_resolver and any other runtime options.
    def configure
      yield config
    end

    # Returns the provider class for a given provider name.
    # Raises ActiveAI::ConfigurationError if the provider is unknown.
    def provider_class_for(provider)
      class_name = PROVIDER_CLASSES[provider.to_s]
      unless class_name
        raise ActiveAI::ConfigurationError,
          "Unknown ActiveAI provider: #{provider.inspect} — " \
          "use #{PROVIDER_CLASSES.keys.join(', ')} or call " \
          "ActiveAI.register_provider to add a custom provider"
      end
      class_name.constantize
    end

    # Registers a custom provider so it works everywhere in ActiveAI:
    # agent routing (Base#provider_class), key storage (ProviderKey validation),
    # and model defaults (HasProviderKeys#model_options_for).
    #
    # Call from an initializer after your provider class is defined:
    #
    #   class GeminiProvider < ActiveAI::Provider::Base
    #     def self.model_defaults = %w[gemini-2.0-flash gemini-1.5-pro]
    #     def stream(params, &block) = ...
    #   end
    #
    #   ActiveAI.register_provider("gemini", "GeminiProvider")
    #
    def register_provider(name, class_name)
      PROVIDER_CLASSES[name.to_s] = class_name
      if defined?(ActiveAI::Credential)
        ActiveAI::Credential.provider_names = (ActiveAI::Credential.provider_names + [ name.to_s ]).uniq
      end
    end

    # Returns an instance of the adapter for a registered vector store name.
    def vector_store_adapter(name = "pgvector")
      class_name = VECTOR_STORE_CLASSES[name.to_s]
      unless class_name
        raise ActiveAI::ConfigurationError,
          "Unknown vector store: #{name.inspect} — " \
          "use #{VECTOR_STORE_CLASSES.keys.join(', ')} or call " \
          "ActiveAI.register_vector_store to add a custom adapter"
      end
      class_name.constantize.new
    end

    # Registers a vector store adapter class.
    #
    #   ActiveAI.register_vector_store("pinecone", "MyPineconeAdapter")
    #
    def register_vector_store(name, class_name)
      VECTOR_STORE_CLASSES[name.to_s] = class_name
    end

    # Prompt file resolvers — load system prompts from app/ai/<type>/prompts/<name>.md.
    # Usage: system_prompt Rails.active_ai.agent.prompt(:embedder)
    #
    def agent        = @agent_prompts        ||= PromptResolver.new("app/ai/agents/prompts")
    def tool         = @tool_prompts         ||= PromptResolver.new("app/ai/tools/prompts")
    def skill        = @skill_prompts        ||= PromptResolver.new("app/ai/skills/prompts")
    def memory       = @memory_prompts       ||= PromptResolver.new("app/ai/memory/prompts")
    def workflow     = @workflow_prompts     ||= PromptResolver.new("app/ai/workflows/prompts")
    def orchestrator = @orchestrator_prompts ||= PromptResolver.new("app/ai/orchestrators/prompts")

    # Registers a tool credential name so it can be stored in ai_credentials
    # and resolved via HasCredentials#api_key_for.
    #
    #   ActiveAI.register_tool_credential("serpapi")
    #   Setting.instance.ai_credentials.create!(category: "tool", name: "serpapi", api_key: "...")
    #
    def register_tool_credential(name)
      if defined?(ActiveAI::Credential)
        ActiveAI::Credential.tool_names = (ActiveAI::Credential.tool_names + [ name.to_s ]).uniq
      end
    end
  end
end
