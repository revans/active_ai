module ActiveAI
  module Skill
    # Base class for static, code-owned skills. Skills inject named content blocks
    # into the agent's context — they shape *how* the agent behaves, not *what* it does.
    #
    # Subclasses declare skill_name and content:
    #
    #   class BlogStructureSkill < ApplicationSkill
    #     skill_name "blog_structure"
    #     content "When writing blog posts, open with the most important point..."
    #   end
    #
    # Active skills that vary by runtime context override content with kwargs:
    #
    #   class CitationSkill < ApplicationSkill
    #     skill_name "citations"
    #     def self.content(document: nil, **)
    #       document ? "Cite sources relevant to: #{document}" : "Cite general sources."
    #     end
    #   end
    #
    # Register on an agent with the skills DSL (accepts a class or an array):
    #
    #   class WritingAgent < ApplicationAgent
    #     skills [BlogStructureSkill, ActiveVoiceSkill]
    #   end
    #
    # Inline strings are also accepted for quick one-off injections:
    #
    #   skills "Always prefer active voice over passive voice."
    #
    # Class-based skills ship with the application and are developer-owned.
    # DB-backed skills (the Skill model) are writer-owned and appended after these.
    class Base
      class_attribute :_skill_name
      class_attribute :_static_content

      def self.skill_name(text = nil)
        if text
          self._skill_name = text
          ActiveAI.register(self) if name.present?
          self
        else
          _skill_name || raise(NotImplementedError, "#{self}.skill_name is not implemented — call `skill_name \"...\"`")
        end
      end

      # DSL for passive skills with static content. Active skills that need
      # runtime context override `def self.content(**kwargs)` instead.
      #
      #   class ToneSkill < ApplicationSkill
      #     content "Always write in a direct, confident tone."
      #   end
      def self.content(text = nil)
        if text
          self._static_content = text
          self
        else
          _static_content || raise(NotImplementedError,
            "#{self}.content is not implemented — call `content \"...\"` for static skills, " \
            "`prompt_file :name` to load from app/ai/skills/prompts/, " \
            "or override `def self.content(**kwargs)` for context-aware skills")
        end
      end

      # Loads skill content from a prompt file at class definition time.
      # Renders app/ai/skills/prompts/<name>.md.erb (or .md) without instance context.
      #
      #   class ToneSkill < ApplicationSkill
      #     skill_name "tone"
      #     prompt_file :tone
      #   end
      def self.prompt_file(name)
        self._static_content = ActiveAI.skill.prompt(name)
        self
      end

      # Returns the canonical skill hash. Passes context to active skills that
      # declare keyword parameters on content(); passive skills (no kwargs) are
      # called without args so existing subclasses require no changes.
      def self.to_definition(context = {})
        caller_ctx = ActiveAI::Instrumentation.current_caller
        result     = nil
        ActiveSupport::Notifications.instrument("skill_resolve.active_ai", {
          skill_name:  _skill_name,
          skill_class: name,
          caller_type: caller_ctx&.dig(:type),
          caller_name: caller_ctx&.dig(:name)
        }) do |notif|
          params     = method(:content).parameters
          has_kwargs = params.any? { |type, _| [ :key, :keyreq, :keyrest ].include?(type) }
          resolved   = has_kwargs ? content(**context) : content
          result     = { name: skill_name, content: resolved }
          notif[:content_length] = resolved.to_s.length
          result
        end
        result
      end
    end
  end
end
