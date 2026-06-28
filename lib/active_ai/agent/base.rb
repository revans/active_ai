require "active_support/core_ext/class/attribute"

module ActiveAI
  module Agent
    # Base class for AI agents. Use class-level declarations to configure:
    #
    #   class WritingAgent < ApplicationAgent
    #     provider :anthropic
    #     model "claude-sonnet-4-6", max_tokens: 8096
    #     cache :system,       ttl: "1h"
    #     cache :source_files, ttl: "1h"
    #     cache :context,      ttl: "5m"
    #   end
    #
    # Subclasses MUST implement `build_messages` — converting @history and @message
    # into the [{role:, content:}] array the provider expects.
    #
    # In practice, app code inherits ApplicationAgent (which implements build_messages)
    # rather than this class directly. Base carries no domain knowledge.
    class Base
      include ActiveAI::Concerns::Describable
      include ActiveSupport::Callbacks

      define_callbacks :complete

      # Lifecycle hooks around complete(). Use method names or blocks.
      #
      #   before_complete :validate_inputs
      #   after_complete  :broadcast_result
      def self.before_complete(*args, &block)
        set_callback(:complete, :before, *args, &block)
      end

      def self.after_complete(*args, &block)
        set_callback(:complete, :after, *args, &block)
      end

      class_attribute :_provider_name, :_model_config, :_cache_config, :_tools, :_system_prompt, :_skills
      class_attribute :provider_model_defaults, default: {}
      self._cache_config = {}
      self._tools        = []
      self._skills       = []

      # Class-level declarations ─────────────────────────────────────────────────

      def self.provider(name)
        self._provider_name = name.to_sym
      end

      def self.model(name_or_callable, max_tokens: nil)
        self._model_config = { name: name_or_callable, max_tokens: max_tokens }
      end

      def self.system_prompt(text)
        self._system_prompt = text
      end

      def self.cache(block_name, ttl: "5m")
        self._cache_config = _cache_config.merge(block_name.to_sym => ttl)
      end

      def self.tools(input)
        self._tools = _tools + Array(input)
      end

      # Accepts a skill class, an array of skill classes, or a plain string.
      # Strings are wrapped as anonymous inline skills. Can be called multiple times.
      #
      #   skills BlogStructureSkill
      #   skills [ToneSkill, VoiceSkill]
      #   skills "Always prefer active voice."
      #
      # Passing an instance raises immediately — a common mistake:
      #   skills ToneSkill.new   # → ArgumentError: pass the class, not an instance
      def self.skills(input)
        items = Array(input).map do |item|
          unless item.is_a?(String) || item.is_a?(Class)
            raise ArgumentError,
              "#{name || self}.skills expects a Skill class or String, got #{item.class.name} instance. " \
              "Pass the class itself (e.g. #{item.class.name}) not an instance (#{item.class.name}.new)."
          end
          item.is_a?(String) ? { name: nil, content: item } : item
        end
        self._skills = _skills + items
      end

      # Convenience entry point — equivalent to new(message: message, **context).complete.
      def self.run(message, **context)
        new(message: message, **context).complete
      end

      # Instance interface ───────────────────────────────────────────────────────

      # Override in subclasses to supply tool instances with injected context.
      # Merged with class-level _tools in all_tools.
      #
      #   def instance_tools
      #     [WriteDocumentTool.new(document: @document)]
      #   end
      def instance_tools
        []
      end

      # All tools available to this agent instance: class-registered + instance-level.
      def all_tools
        self.class._tools + instance_tools
      end

      # Returns the resolved model name string.
      # Priority: runtime kwarg → class declaration (callable or string) → provider_model_defaults → config/ai.yml default.
      def resolved_model
        return @runtime_model if @runtime_model.present?
        if (model_config = self.class._model_config).present?
          model_name = model_config[:name]
          return model_name.respond_to?(:call) ? model_name.call : model_name
        end
        provider_default = self.class.provider_model_defaults[resolved_provider]
        return provider_default if provider_default.present?
        ActiveAI.config.model
      end

      # Returns the resolved provider name symbol.
      # Priority: runtime kwarg → class declaration → config/ai.yml default.
      def resolved_provider
        (@runtime_provider || self.class._provider_name || ActiveAI.config.provider).to_sym
      end

      # Public alias for build_params — stable name for external callers and tests.
      def to_canonical_params
        build_params
      end

      # Maximum number of tool-call iterations in a single stream invocation.
      # Prevents infinite loops when the model keeps requesting tools without
      # producing a final text response. Increase if an agent legitimately needs more.
      MAX_TOOL_ITERATIONS = 20

      # Streaming call — agentic loop. Yields String chunks for text deltas
      # and { tool_call: { id:, name:, input: } } hashes for tool invocations.
      # A block is required — calling stream without one raises ArgumentError immediately.
      def stream(&block)
        raise ArgumentError,
          "#{self.class.name}#stream requires a block — use: agent.stream { |event| ... }" unless block_given?

        @last_tool_call_results = []
        params   = build_params
        @last_sent_messages  = params[:messages]
        @last_system_prompt  = params[:system]
        messages = params[:messages]

        validate_tool_names!(params[:tools])

        payload = {
          agent_class: self.class.name,
          provider:    resolved_provider,
          model:       resolved_model
        }

        iterations = 0

        ActiveSupport::Notifications.instrument("agent_stream.active_ai", payload) do |notif|
          loop do
            iterations += 1
            if iterations > MAX_TOOL_ITERATIONS
              raise ToolLoopError,
                "#{self.class.name} exceeded #{MAX_TOOL_ITERATIONS} tool call iterations — " \
                "possible infinite loop. Increase ActiveAI::Agent::Base::MAX_TOOL_ITERATIONS if the " \
                "agent legitimately needs more turns."
            end

            @last_provider_instance = provider_instance
            @last_provider_instance.stream(params.merge(messages: messages), &block)

            tool_calls = @last_provider_instance.last_tool_calls
            break if tool_calls.blank?

            tool_results = execute_tool_calls(tool_calls, &block)
            messages = messages +
              [@last_provider_instance.format_assistant_turn(
                @last_provider_instance.last_assistant_content,
                tool_calls
              )] +
              @last_provider_instance.format_tool_result_messages(tool_results)
          end
          notif[:usage]      = last_usage
          notif[:tool_calls] = last_tool_call_results
        end
      end

      # Blocking call — runs the same agentic loop as stream, accumulates the full response string.
      # Fires active_ai.agent.complete (or active_ai.orchestrator.route for Orchestrator subclasses).
      # before_complete and after_complete callbacks fire around the stream loop.
      def complete
        caller_ctx = ActiveAI::Instrumentation.current_caller
        payload    = build_complete_payload(caller_ctx)
        result     = nil

        ActiveSupport::Notifications.instrument(complete_event_name, payload) do |notif|
          ActiveAI::Instrumentation.with_caller(type: caller_type_sym, name: self.class.name) do
            run_callbacks(:complete) do
              accumulated_text = String.new
              stream { |event| accumulated_text << event if event.is_a?(String) }
              result = accumulated_text
              finalize_complete_notification(notif, accumulated_text)
              result
            end
          end
        end

        result
      end

      # Usage data from the last call — full breakdown including cache tokens.
      def last_usage
        @last_provider_instance&.last_usage
      end

      # Results from tool calls in the last stream invocation.
      def last_tool_call_results
        @last_tool_call_results ||= []
      end

      # Number of history messages included in the last call.
      def history_count
        Array(@history).size
      end

      private

      # Builds the canonical params hash for the provider. Calls build_system_prompt,
      # skill_context, validate_history!, and build_messages — override those hooks
      # rather than this method.
      def build_params
        validate_history!
        {
          model:        resolved_model,
          max_tokens:   self.class._model_config&.fetch(:max_tokens, nil) || ActiveAI.config.max_tokens,
          system:       build_system_prompt,
          skills:       self.class._skills.map { |s| s.respond_to?(:to_definition) ? s.to_definition(skill_context) : s } +
                        @skills.map { |s| { id: s.id, name: s.name, content: s.content } },
          source_files: @source_files,
          messages:     build_messages,
          cacheable:    self.class._cache_config,
          tools:        all_tools.map(&:to_definition)
        }
      end

      # Returns the system prompt string. Override to add memory recall, custom
      # prompt assembly, or other app-specific prompt behavior — call super for
      # the base value then prepend or append your additions.
      #
      #   def build_system_prompt
      #     base   = super
      #     memory = recalled_memory_block
      #     [memory, base].select(&:present?).join("\n\n")
      #   end
      def build_system_prompt
        (@system.presence || self.class._system_prompt).to_s
      end

      # Returns the context hash passed to skill definitions that accept context.
      def skill_context
        { message: @message, context: @context }
      end

      # Validates @history for Anthropic's strictly-alternating role contract.
      # Raises ArgumentError on blank roles or consecutive same-role messages.
      # Called from build_params before build_messages.
      def validate_history!
        raw_roles = []
        Array(@history).each_with_index do |msg, i|
          role = msg.role.to_s
          raise ArgumentError,
            "History message at index #{i} has a blank role — every message must have role \"user\" or \"assistant\"" if role.blank?
          raw_roles << role
        end
        raw_roles.each_cons(2) do |prev, curr|
          next unless prev == curr
          raise ArgumentError,
            "Consecutive #{curr.inspect} messages in history violate Anthropic's strictly alternating user/assistant requirement"
        end
      end

      # Subclasses MUST implement. Convert @history (your app's message records)
      # and @message into [{role:, content:}] hashes for the provider.
      def build_messages
        raise NotImplementedError, "#{self.class}#build_messages must be implemented. " \
          "Convert @history (your app's message records) and @message into [{role:, content:}] hashes."
      end

      def execute_tool_calls(tool_calls, &block)
        tool_calls.map { |tool_call| execute_single_tool_call(tool_call, &block) }
      end

      def execute_single_tool_call(tool_call, &block)
        registered_tool = all_tools.find { |candidate| candidate.tool_name == tool_call[:name] }
        call_result     = nil

        caller_ctx = ActiveAI::Instrumentation.current_caller
        ActiveSupport::Notifications.instrument("tool_call.active_ai", {
          tool_name:   tool_call[:name],
          tool_class:  registered_tool.is_a?(Class) ? registered_tool.name : registered_tool&.class&.name,
          input:       tool_call[:input],
          caller_type: caller_ctx&.dig(:type),
          caller_name: caller_ctx&.dig(:name)
        }) do |notification|
          call_result = begin
            if registered_tool
              registered_tool.call(**tool_call[:input].transform_keys(&:to_sym))
            else
              "Unknown tool: #{tool_call[:name]}"
            end
          rescue => tool_error
            Rails.logger.error(
              "ActiveAI: tool #{tool_call[:name]} raised #{tool_error.class}: #{tool_error.message}"
            )
            "Error: #{tool_error.class} — #{tool_error.message}"
          end
          notification[:result] = call_result
        end

        yield({ tool_call: { id: tool_call[:id], name: tool_call[:name], input: tool_call[:input] } })

        @last_tool_call_results << { id: tool_call[:id], name: tool_call[:name], result: call_result }
        { type: "tool_result", tool_use_id: tool_call[:id], content: call_result.to_s }
      end

      # Raises ArgumentError when the resolved tool list contains duplicate names.
      # Called once at the start of every stream invocation, before the first
      # provider call, so the developer gets a clear error rather than a cryptic
      # Anthropic 400/422 at runtime.
      def validate_tool_names!(tools)
        names = tools.map { |t| t[:name] }
        dupes = names.select { |n| names.count(n) > 1 }.uniq
        return if dupes.empty?
        raise ActiveAI::ConfigurationError,
          "#{self.class.name} has duplicate tool names: #{dupes.join(', ')} — " \
          "each tool registered on an agent must have a unique name."
      end

      # ── Instrumentation template methods ──────────────────────────────────────
      # Orchestrator::Base overrides these to fire active_ai.orchestrator.route
      # with an orchestrator-specific payload instead of active_ai.agent.complete.

      def complete_event_name
        "agent_complete.active_ai"
      end

      def caller_type_sym
        :agent
      end

      def build_complete_payload(caller_ctx)
        {
          agent_class: self.class.name,
          provider:    resolved_provider,
          model:       resolved_model,
          caller_type: caller_ctx&.dig(:type),
          caller_name: caller_ctx&.dig(:name)
        }
      end

      def finalize_complete_notification(notif, response)
        notif[:messages]      = @last_sent_messages
        notif[:system_prompt] = @last_system_prompt
        notif[:response]      = response
        notif[:usage]         = last_usage
        notif[:tool_calls]    = last_tool_call_results
      end

      # Loads a prompt file from app/ai/prompts/<name>.md (or .txt).
      # Shorthand for Rails.application.active_ai.prompt(name) inside build_params.
      def prompt(name)
        Rails.application.active_ai.prompt(name)
      end

      def provider_instance
        provider_class.new
      end

      def provider_class
        ActiveAI.provider_class_for(resolved_provider)
      end
    end
  end
end
