module ActiveAI
  class Engine < Rails::Engine
    initializer "active_ai.configuration" do
      ActiveAI.instance_variable_set(:@config, ActiveAI::Configuration.load_from_file)
    end

    initializer "active_ai.application" do |app|
      app.define_singleton_method(:active_ai) { ActiveAI::Application.instance }
    end

    initializer "active_ai.rails_accessor" do
      Rails.singleton_class.define_method(:active_ai) { ::ActiveAI }
    end

    # Collapse app/ai subdirectories so they're organisational groupings, not
    # namespaces. WritingAgent in app/ai/agents/ stays WritingAgent, the same
    # way UsersController in app/controllers/ stays UsersController.
    config.before_initialize do |app|
      %w[agents tools skills commands workflows orchestrators memory concerns].each do |dir|
        path = app.root.join("app/ai", dir).to_s
        Rails.autoloaders.main.collapse(path) if Dir.exist?(path)
      end
    end

    # app/ai/commands is resolved entirely through ActiveAI.commands (a
    # registry scan) — unlike agents/tools, nothing in an app directly
    # references a Command subclass by constant, so nothing would ever
    # trigger its autoload. Without eager loading this directory specifically,
    # ActiveAI.commands returns an empty array in any environment that
    # doesn't eager_load the whole app (i.e. every environment except
    # production). This runs on every to_prepare (boot, and before each
    # request in development after a reload) so newly-added or reloaded
    # command classes are always present in the registry.
    config.to_prepare do
      path = Rails.application.root.join("app/ai/commands").to_s
      Rails.autoloaders.main.eager_load_dir(path) if Dir.exist?(path)
    end
  end
end
