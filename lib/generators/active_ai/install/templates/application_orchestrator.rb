class ApplicationOrchestrator < ActiveAI::Orchestrator
  self.provider_model_defaults = {
    anthropic: "claude-sonnet-4-6",
    openai:    "gpt-4.1",
    xai:       "grok-3"
  }
end
