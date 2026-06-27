class ApplicationAgent < ActiveAI::Base
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

  def build_params
    {
      model:        resolved_model,
      max_tokens:   self.class._model_config&.fetch(:max_tokens, nil) || ActiveAI.config.max_tokens,
      system:       @system.to_s,
      skills:       self.class._skills.map { |s| s.respond_to?(:to_definition) ? s.to_definition(skill_context) : s } +
                    @skills.map { |s| { id: s.id, name: s.name, content: s.content } },
      source_files: @source_files,
      messages:     build_messages,
      cacheable:    self.class._cache_config,
      tools:        all_tools.map(&:to_definition)
    }
  end

  def skill_context
    { message: @message, context: @context }
  end

  def build_messages
    messages = []

    if @context.present?
      messages << { role: "user",      content: @context.to_s }
      messages << { role: "assistant", content: "Understood. I have read the full document. What would you like to discuss?" }
    end

    # Pre-validate history against Anthropic's role requirements before building.
    # Checks blank roles and consecutive same-role violations in the raw sequence.
    # Blank-content messages are skipped below but still counted in the raw role sequence
    # so that [user, blank-assistant, user] does not trigger a consecutive-role error —
    # only genuinely adjacent same-role messages (with no separator at all) raise.
    raw_roles = messages.map { |m| m[:role] }
    @history.each_with_index do |msg, i|
      role = msg.role.to_s
      if role.blank?
        raise ArgumentError,
          "History message at index #{i} has a blank role — every message must have role \"user\" or \"assistant\""
      end
      raw_roles << role
    end
    raw_roles.each_cons(2) do |prev, curr|
      next unless prev == curr
      raise ArgumentError,
        "Consecutive #{curr.inspect} messages in history violate Anthropic's strictly alternating user/assistant requirement"
    end

    @history.each do |msg|
      content = msg.content.to_s
      next if content.blank?  # Anthropic rejects content: "" or content: nil

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
