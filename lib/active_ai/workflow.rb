module ActiveAI
  # Base class for multi-agent workflows. Coordinates sequential agent handoffs
  # without making any LLM calls itself — it is a coordinator, not a participant.
  #
  # Subclasses override run(input) and call step() to execute each agent in order.
  # The return value of one step is a plain string that the next step receives as input.
  #
  #   class ResearchAndWriteWorkflow < ApplicationWorkflow
  #     def run(input)
  #       research = step(ResearchAgent, message: input)
  #       step(WritingAgent, message: research, context: input)
  #     end
  #   end
  #
  #   # Class-level convenience — delegates to new.run(input)
  #   result = ResearchAndWriteWorkflow.run("Tell me about photosynthesis")
  #
  #   # Or construct with context when the workflow itself needs injected state
  #   result = DocWorkflow.new(document: @document).run(user_message)
  #
  # Each step fires a "step.active_ai" notification. Subscribe to pipe step data
  # to a log file, database table, or any other sink:
  #
  #   ActiveSupport::Notifications.subscribe("step.active_ai") do |event|
  #     WorkflowStepLog.create!(
  #       workflow:      event.payload[:workflow_class],
  #       agent:         event.payload[:agent_class],
  #       input_length:  event.payload[:input_length],
  #       output_length: event.payload[:output_length],
  #       usage:         event.payload[:usage],
  #       duration_ms:   event.duration
  #     )
  #   end
  #
  class Workflow
    include ActiveAI::Concerns::Instrumentable
    include ActiveAI::Concerns::Describable

    # Class-level convenience. Use new(...).run(input) when the workflow needs
    # injected constructor state (e.g. a document or current user).
    # The ** absorbs any context kwargs passed by an Orchestrator via context_for.
    def self.run(input, **)
      new.run(input)
    end

    # Override in subclasses. Call step() or parallel_step() to coordinate work.
    # Returns whatever the final step (or any explicit return) produces.
    def run(input)
      raise NotImplementedError, "#{self.class}#run is not implemented"
    end

    private

    # Runs a single step — either an agent (full LLM loop) or a tool (direct call).
    #
    # Agent step:   step(ResearchAgent, message: input)
    # Tool class:   step(ActiveAI::Tools::WebSearch, query: input)
    # Tool instance: step(WriteDocumentSectionTool.new(document: @doc), topic: "intro", content: html)
    #
    # Fires "step.active_ai" with:
    #   :workflow_class — name of this workflow class
    #   :agent_class    — name of the agent or tool class that ran
    #   :input_length   — character length of the :message kwarg (proxy for input size)
    #   :output_length  — character length of the response (set after completion)
    #   :usage          — token usage hash from the agent; nil for tool steps
    def step(target, **kwargs)
      is_tool   = target.is_a?(ActiveAI::Tool::Base) ||
                  (target.is_a?(Class) && target <= ActiveAI::Tool::Base)
      step_name = target.is_a?(Class) ? target.name : target.class.name

      instrument_step(step_name, input_length: kwargs[:message].to_s.length) do |notification|
        if is_tool
          target.call(**kwargs)
        else
          agent                = target.new(**kwargs)
          result               = agent.complete
          notification[:usage] = agent.last_usage
          result
        end
      end
    end

    # Runs multiple steps concurrently in threads and returns their results in
    # the same order as the input entries. Each step fires its own step.active_ai
    # notification from within its thread. The whole batch fires a single
    # parallel_step.active_ai notification wrapping all of them.
    #
    #   results = parallel_step(
    #     [ResearchAgent,  { message: "angle 1" }],
    #     [FactCheckAgent, { message: "claim" }]
    #   )
    #   step(WritingAgent, message: results.join("\n\n"))
    #
    # Raises if any thread raises — no partial result recovery in V1.
    def parallel_step(*entries)
      step_names = entries.map { |(target, _)| target.is_a?(Class) ? target.name : target.class.name }
      results    = nil

      ActiveSupport::Notifications.instrument("parallel_step.active_ai", {
        workflow_class: self.class.name,
        steps:          step_names,
        count:          entries.length
      }) do |notification|
        threads = entries.map do |(target, kwargs)|
          name = target.is_a?(Class) ? target.name : target.class.name
          Thread.new { { agent: name, response: step(target, **(kwargs || {})) } }
        end
        results                      = threads.map(&:value)
        notification[:results_count] = results.length
      end

      results
    end
  end
end
