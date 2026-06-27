module ActiveAI
  module Memory
    # Base class for application-level memory configuration.
    # Inherit from this (via ApplicationMemory) to define how memory
    # works for a specific agent, orchestrator, or skill context.
    #
    # DSL is class-level — subclasses declare their defaults:
    #
    #   class WriterAgentMemory < ApplicationMemory
    #     recall_strategy :hybrid
    #     token_budget 1200
    #     scope "introduction"
    #   end
    #
    # Behavior wiring (which agent uses which memory class, how the
    # recall result is injected) is deferred — this class owns the
    # configuration surface and the home for future logic.
    class Base
      class << self
        def recall_strategy(value = nil)
          value ? @recall_strategy = value : (@recall_strategy || :warm)
        end

        def token_budget(value = nil)
          value ? @token_budget = value : (@token_budget || 800)
        end

        def scope(value = nil)
          value ? @scope = value : @scope
        end

        # Convenience: call Memory.recall using this class's configured defaults.
        # Override in subclasses to add agent/user/subject context.
        def recall(user: nil, agent: nil, subject: nil, **opts)
          ActiveAI::Memory.recall(
            user:             user,
            agent:            agent,
            subject:          subject,
            scope:            opts.fetch(:scope, @scope),
            strategy:         opts.fetch(:strategy, recall_strategy),
            token_budget:     opts.fetch(:token_budget, token_budget)
          )
        end
      end
    end
  end
end
