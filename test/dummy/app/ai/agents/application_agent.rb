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

  def build_messages
    messages = []

    if @context.present?
      messages << { role: "user",      content: @context.to_s }
      messages << { role: "assistant", content: "Understood. I have read the full document. What would you like to discuss?" }
    end

    @history.each do |msg|
      content = msg.content.to_s
      next if content.blank?

      if msg.attached_file_content.present?
        content = "Attached file — #{msg.attached_file_name}:\n#{msg.attached_file_content}\n\n#{content}"
      end
      messages << { role: msg.role.to_s, content: content }
    end

    if @message.present?
      parts = []
      parts << "Selected text:\n#{@focus}" if @focus.present?
      parts << "Attached file — #{@file_name}:\n#{@file_content}" if @file_content.present?
      parts << @message
      messages << { role: "user", content: parts.join("\n\n") }
    end

    messages
  end
end
