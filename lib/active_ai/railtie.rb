module ActiveAI
  class Railtie < Rails::Railtie
    initializer "active_ai.configuration" do
      ActiveAI.instance_variable_set(:@config, ActiveAI::Configuration.load_from_file)
    end

    initializer "active_ai.application" do |app|
      app.define_singleton_method(:active_ai) { ActiveAI::Application.instance }
    end

    initializer "active_ai.rails_accessor" do
      # Rails.active_ai mirrors Rails.application — a single access point for
      # prompt resolvers, config, and the registry from anywhere in the app.
      Rails.singleton_class.define_method(:active_ai) { ::ActiveAI }
    end

    # Add gem's app/models to autoload paths so AR models are discovered.
    # Must run before :load_config_initializers so paths aren't frozen yet.
    config.before_initialize do |app|
      gem_app_path = File.expand_path("../../../app", __dir__)
      app.config.autoload_paths  += [gem_app_path]
      app.config.eager_load_paths += [gem_app_path]

      # Collapse app/ai subdirectories so they're organisational groupings, not
      # namespaces. WritingAgent in app/ai/agents/ stays WritingAgent, the same
      # way UsersController in app/controllers/ stays UsersController.
      %w[agents tools skills workflows orchestrators memory].each do |dir|
        path = app.root.join("app/ai", dir).to_s
        Rails.autoloaders.main.collapse(path) if Dir.exist?(path)
      end
    end
  end
end
