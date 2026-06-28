class ApplicationAgent < ActiveAI::Agent::Base
  include ActiveAI::Orchestratable
  include ActiveAI::Promptable
  prompt_namespace :agent

  # Default models per provider — used when a subclass declares `provider` but not `model`.
  # Override per-agent with: model "claude-opus-4-8", max_tokens: 4096
  PROVIDER_MODEL_DEFAULTS = {
    anthropic: "claude-sonnet-4-6",
    openai:    "gpt-4.1",
    xai:       "grok-3"
  }.freeze

  def resolved_model
    return super if self.class._model_config.present? || @runtime_model.present?
    PROVIDER_MODEL_DEFAULTS[resolved_provider] || super
  end

  def initialize(system: nil, context: nil, source_files: [], history: [],
                 skills: [], focus: nil, message: nil,
                 file_name: nil, file_content: nil, provider: nil, model: nil)
    @system           = system
    @context          = context
    @source_files     = Array(source_files)
    @history          = Array(history)
    @skills           = Array(skills)
    @focus            = focus
    @message          = message
    @file_name        = file_name
    @file_content     = file_content
    @runtime_provider = provider
    @runtime_model    = model
  end

  private

  # IMPLEMENT ME: convert your app's message records into [{role:, content:}] hashes.
  # This is called once per request, before the provider call.
  #
  # @history  — array of your app's Message records (ActiveRecord or POROs)
  # @message  — the current user message string
  # @context  — optional string prepended as context before the history
  #
  # Example:
  #
  #   def build_messages
  #     messages = []
  #
  #     if @context.present?
  #       messages << { role: "user",      content: @context.to_s }
  #       messages << { role: "assistant", content: "Understood." }
  #     end
  #
  #     @history.each do |msg|
  #       next if msg.content.blank?
  #       messages << { role: msg.role.to_s, content: msg.content.to_s }
  #     end
  #
  #     messages << { role: "user", content: @message } if @message.present?
  #     messages
  #   end
  def build_messages
    raise NotImplementedError,
      "#{self.class.name}#build_messages is not implemented. " \
      "Open app/ai/agents/application_agent.rb and fill in the build_messages method."
  end
end
