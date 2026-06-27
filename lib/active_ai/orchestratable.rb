module ActiveAI
  # Marker module. Any class that includes this can be registered in an
  # Orchestrator via agent() or workflow().
  #
  # Including classes must respond to self.run(message, **context) —
  # the normalized entry point the Orchestrator uses to invoke them.
  #
  # Agents inherit run from ActiveAI::Base. Workflows inherit run from
  # ActiveAI::Workflow. Custom classes must implement it themselves.
  #
  module Orchestratable
  end
end
