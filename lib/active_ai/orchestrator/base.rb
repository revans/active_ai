module ActiveAI
  module Orchestrator
    # Orchestrator is a meta-agent — an LLM that routes work to other agents and
    # workflows rather than doing the work itself. The LLM decides which to invoke,
    # in what order, and whether to invoke them at all.
    #
    # Registered agents and workflows must include ActiveAI::Orchestratable.
    # The Orchestrator calls klass.run(message, **context) on each — agents
    # inherit run from ActiveAI::Agent::Base, workflows from ActiveAI::Workflow::Base.
    # Regular tools (Tool::Base subclasses) can also be registered via the
    # inherited tool() DSL from ActiveAI::Agent::Base alongside agent/workflow meta-tools.
    #
    #   class ResearchOrchestrator < ApplicationOrchestrator
    #     provider :anthropic
    #     model "claude-opus-4-8", max_tokens: 4096
    #     system_prompt "You are a research coordinator. Only call an agent if needed."
    #
    #     tools WebSearchTool                                        # regular tool
    #     agent FactCheckAgent,           description: "Verifies claims"
    #     workflow ResearchWriteWorkflow, description: "Full research pipeline"
    #   end
    #
    # Override context_for(klass) to supply per-class runtime context. The hash
    # is merged into the run_with_message call for that specific class:
    #
    #   class DocOrchestrator < ApplicationOrchestrator
    #     def initialize(message:, document:)
    #       super(message: message)
    #       @document = document
    #     end
    #
    #     agent WritingAgent,  description: "Writes document sections",
    #                          context: -> { { document: @document } }
    #     agent ResearchAgent, description: "Researches topics"
    #   end
    #
    # The context: lambda is instance_exec'd on the orchestrator at call time, so it
    # can reference @instance_variables set in initialize. Falls back to context_for(klass)
    # when no lambda is provided (backwards compatible).
    #
    class Base < ActiveAI::Agent::Base
      include ActiveAI::Concerns::Instrumentable

      class_attribute :_meta_tool_factories, default: []
      class_attribute :_system_prompt_file,  default: nil

      # Loads the system prompt from a file at call time rather than inline.
      # Renders app/ai/orchestrators/prompts/<name>.md.erb (or .md) without instance context.
      #
      #   class WritingOrchestrator < ApplicationOrchestrator
      #     provider :anthropic
      #     model "claude-opus-4-8", max_tokens: 8096
      #     prompt_file :writing
      #
      #     agent EditingAgent,   description: "Edits and refines prose"
      #     agent ResearchAgent,  description: "Researches topics"
      #   end
      #
      def self.prompt_file(name)
        self._system_prompt_file = name
      end

      # Register an agent as a callable meta-tool. Must include Orchestratable.
      # description: falls back to the agent class's declared description if not provided.
      # context: optional lambda instance_exec'd on the orchestrator at call time to
      #          supply per-call context. Falls back to context_for(klass) when absent.
      def self.agent(agent_class, description: agent_class._description, context: nil)
        raise ArgumentError, "#{agent_class} has no description. Declare `description` on the class or pass description: here." unless description
        unless agent_class.include?(ActiveAI::Orchestratable)
          raise ArgumentError, "#{agent_class} must include ActiveAI::Orchestratable to be registered in an Orchestrator"
        end
        unless agent_class.respond_to?(:run)
          raise ArgumentError,
            "#{agent_class} must implement self.run(message, **context) to be registered. " \
            "Classes inheriting ApplicationAgent get this automatically via ActiveAI::Agent::Base."
        end
        _add_meta_tool_factory(agent_class, description: description, context: context)
      end

      # Register a workflow as a callable meta-tool. Must include Orchestratable.
      # description: falls back to the workflow class's declared description if not provided.
      # context: optional lambda instance_exec'd on the orchestrator at call time to
      #          supply per-call context. Falls back to context_for(klass) when absent.
      def self.workflow(workflow_class, description: workflow_class._description, context: nil)
        raise ArgumentError, "#{workflow_class} has no description. Declare `description` on the class or pass description: here." unless description
        unless workflow_class.include?(ActiveAI::Orchestratable)
          raise ArgumentError, "#{workflow_class} must include ActiveAI::Orchestratable to be registered in an Orchestrator"
        end
        unless workflow_class.respond_to?(:run)
          raise ArgumentError,
            "#{workflow_class} must implement self.run(input, **context) to be registered. " \
            "Classes inheriting ApplicationWorkflow get this automatically via ActiveAI::Workflow::Base."
        end
        _add_meta_tool_factory(workflow_class, description: description, context: context)
      end

      def initialize(message:)
        @message = message
      end

      # Override in subclasses to supply per-class runtime context to meta-tools.
      # The returned hash is merged into run(message, **context).
      #
      #   def context_for(klass)
      #     klass == WritingAgent ? { document: @document } : {}
      #   end
      def context_for(klass)
        {}
      end

      # Meta-tools are instance-level so they close over this orchestrator instance
      # and can call context_for(klass) for per-class runtime context.
      def instance_tools
        self.class._meta_tool_factories.map { |factory| factory.call(self) }
      end

      private

      def complete_event_name
        "orchestrator_route.active_ai"
      end

      def caller_type_sym
        :orchestrator
      end

      def build_complete_payload(caller_ctx)
        {
          orchestrator_class: self.class.name,
          provider:           resolved_provider,
          model:              resolved_model,
          message:            @message,
          caller_type:        caller_ctx&.dig(:type),
          caller_name:        caller_ctx&.dig(:name)
        }
      end

      def finalize_complete_notification(notif, response)
        notif[:response]      = response
        notif[:usage]         = last_usage
        notif[:dispatched_to] = last_tool_call_results.map { |t| t[:name] }
      end

      def build_params
        {
          model:        resolved_model,
          max_tokens:   self.class._model_config&.fetch(:max_tokens, nil) || ActiveAI.config.max_tokens,
          system:       resolved_system_prompt,
          skills:       self.class._skills.map { |skill| skill.respond_to?(:to_definition) ? skill.to_definition : skill },
          source_files: [],
          messages:     [ { role: "user", content: @message } ],
          cacheable:    self.class._cache_config,
          tools:        all_tools.map(&:to_definition)
        }
      end

      def resolved_system_prompt
        if (file = self.class._system_prompt_file)
          ActiveAI.orchestrator._prompt_in_context(file, self)
        else
          self.class._system_prompt.to_s
        end
      end

      class << self
        private

        def _add_meta_tool_factory(klass, description:, context: nil)
          tool_name_string = klass.name.demodulize.underscore
          tool_description = description
          context_lambda   = context

          factory = ->(orchestrator) do
            meta = Class.new(ActiveAI::Tool::Base) do
              define_singleton_method(:tool_name)   { tool_name_string }
              define_singleton_method(:description) { tool_description }
              param :message, type: :string, description: "The task or input to pass to #{tool_name_string}"
              define_method(:call) do |message:|
                orchestrator.__send__(:instrument_step, tool_name_string,
                  input_length: message.to_s.length,
                  event: "orchestrator_dispatch.active_ai") do
                  ctx = context_lambda ? orchestrator.instance_exec(&context_lambda) : orchestrator.context_for(klass)
                  klass.run(message, **ctx)
                end
              end
            end
            meta.new
          end

          self._meta_tool_factories = _meta_tool_factories + [factory]
        end
      end
    end
  end
end
