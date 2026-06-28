module ActiveAI
  module Concerns
    # Provides instrument_step — a private helper that fires "step.active_ai"
    # around a block of work. Include in any class that coordinates agent or
    # tool dispatch (Workflow, Orchestrator) so the notification logic lives
    # in one place rather than being duplicated at each coordination site.
    #
    # The block receives the live notification hash, allowing callers to
    # annotate it with runtime data (e.g. :usage from an agent):
    #
    #   instrument_step("WritingAgent", input_length: message.length) do |notification|
    #     agent  = WritingAgent.new(message: message)
    #     result = agent.complete
    #     notification[:usage] = agent.last_usage
    #     result
    #   end
    #
    module Instrumentable
      private

      # Fires a step-level notification. event: defaults to active_ai.workflow.step
      # but orchestrators pass active_ai.orchestrator.dispatch to distinguish dispatches
      # from workflow steps.
      def instrument_step(target_name, input_length:, event: "active_ai.workflow.step")
        caller_ctx = ActiveAI::Instrumentation.current_caller
        result     = nil
        ActiveSupport::Notifications.instrument(event, {
          source_class: self.class.name,
          step_name:    target_name,
          input_length: input_length,
          caller_type:  caller_ctx&.dig(:type),
          caller_name:  caller_ctx&.dig(:name)
        }) do |notification|
          result                       = yield notification
          notification[:output_length] = result.to_s.length
        end
        result
      end
    end
  end
end
