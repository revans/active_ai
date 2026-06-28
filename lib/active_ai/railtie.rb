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
      %w[agents tools skills workflows orchestrators memory].each do |dir|
        path = app.root.join("app/ai", dir).to_s
        Rails.autoloaders.main.collapse(path) if Dir.exist?(path)
      end
    end
  end
end
