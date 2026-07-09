require "active_support/core_ext/class/attribute"

module ActiveAI
  module Command
    # Base class for typed chat commands — text a human types (e.g. "/invite
    # editor") that is recognized and dispatched before it becomes a normal
    # chat message. Structurally parallel to ActiveAI::Tool::Base: identity
    # DSL, self-registration via Describable, and a `call` contract the base
    # declares and subclasses implement.
    #
    # Where a tool is invoked by the LLM mid-turn with LLM-chosen arguments, a
    # command is invoked by a human typing recognized text, with its (at most
    # one) argument already captured by client-side trigger matching before
    # the request is sent.
    #
    # Commands are always instance-based — every command operates on a
    # specific document within a specific controller's response, so unlike
    # Tool::Base there is no stateless/class-based call style. The app-level
    # ApplicationCommand base class injects that per-request state
    # (document:/controller:); Command::Base itself only declares identity.
    #
    #   class LeaveEditorCommand < ApplicationCommand
    #     command_name "leave_editor"
    #     description "Dismisses the Editor from the document's conversation."
    #     trigger phrase: "/leave editor"
    #     response_type :json
    #
    #     def call(argument: nil)
    #       @controller.render json: { ok: true, left: true }
    #     end
    #   end
    class Base
      include ActiveAI::Concerns::Describable

      RESPONSE_TYPES = %i[stream json].freeze

      class_attribute :_command_name, :_trigger, :_response_type

      # ── Command identity DSL ─────────────────────────────────────────────

      def self.command_name(text = nil)
        if text
          self._command_name = text
          self
        else
          _command_name || raise(NotImplementedError, "#{self}.command_name is not implemented — call `command_name \"...\"`")
        end
      end

      # Declares what recognizes this command client-side. Exactly one of:
      #
      #   trigger phrase: "/invite editor"   # exact match, no argument
      #   trigger prefix:  "/search"         # leading match, captures trailing
      #                                      # text as the `argument:` call kwarg
      def self.trigger(phrase: nil, prefix: nil)
        return _trigger || raise(NotImplementedError, "#{self}.trigger is not declared — call `trigger phrase: \"...\"` or `trigger prefix: \"...\"`") if phrase.nil? && prefix.nil?
        raise ArgumentError, "#{self}.trigger accepts exactly one of phrase: or prefix:" if phrase && prefix

        self._trigger = phrase ? { type: :phrase, phrase: phrase } : { type: :prefix, prefix: prefix }
      end

      # Declares how the client must consume this command's response —
      # :stream (SSE, opened with a reader loop) or :json (a single
      # response.json() await). Required: without it the client dispatcher
      # cannot generically decide how to read the response.
      def self.response_type(type = nil)
        if type
          raise ArgumentError, "#{self}.response_type must be one of #{RESPONSE_TYPES.inspect}, got #{type.inspect}" unless RESPONSE_TYPES.include?(type.to_sym)
          self._response_type = type.to_sym
        else
          _response_type || raise(NotImplementedError, "#{self}.response_type is not declared — call `response_type :stream` or `response_type :json`")
        end
      end

      # Anthropic-tool-definition-style hash, injected client-side as the
      # server-rendered command list (data-chat-commands-value).
      def self.to_definition
        {
          name:          command_name,
          trigger:       trigger,
          response_type: response_type
        }
      end

      def call(argument: nil)
        raise NotImplementedError, "#{self.class}#call is not implemented"
      end

      # Instance delegates — mirrors Tool::Base, so a Command instance
      # exposes the same identity interface as its class.
      def command_name   = self.class.command_name
      def description    = self.class.description
      def trigger        = self.class.trigger
      def response_type  = self.class.response_type
      def to_definition  = self.class.to_definition
    end
  end
end
