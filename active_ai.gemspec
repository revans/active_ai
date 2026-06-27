require_relative "lib/active_ai/version"

Gem::Specification.new do |spec|
  spec.name        = "active_ai"
  spec.version     = ActiveAI::VERSION
  spec.authors     = ["Robert Evans"]
  spec.email       = ["robert@codewranglers.org"]
  spec.summary     = "Rails-first AI conversation library"
  spec.description = "ActionMailer-style AI conversations for Rails. " \
                     "Providers, agentic loop, streaming, tool execution, and instrumentation."
  spec.homepage    = "https://github.com/revans/active_ai"
  spec.license     = "MIT"

  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*.rb", "lib/**/*.tt", "active_ai.gemspec", "README.md"]

  spec.require_paths = ["lib"]

  spec.add_dependency "rails", ">= 7.0"
  spec.add_dependency "anthropic"
  spec.add_dependency "ruby-openai"
end
