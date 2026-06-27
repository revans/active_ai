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

      def instrument_step(target_name, input_length:)
        result = nil
        ActiveSupport::Notifications.instrument("step.active_ai", {
          workflow_class: self.class.name,
          agent_class:    target_name,
          input_length:   input_length
        }) do |notification|
          result                       = yield notification
          notification[:output_length] = result.to_s.length
        end
        result
      end
    end
  end
end
