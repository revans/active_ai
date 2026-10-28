require "rails/generators"
require "rails/generators/active_record"

module ActiveAI
  module Generators
    # rails generate active_ai:event_log
    #
    # Stores every ActiveAI event — prompts, answers, tool calls, queries — as a row in
    # active_ai_events, through a connection of its own so a run's events survive the
    # app's transaction rolling back.
    class EventLogGenerator < Rails::Generators::Base
      namespace "active_ai:event_log"
      include ActiveRecord::Generators::Migration
      source_root File.expand_path("templates", __dir__)
      desc "Creates the active_ai_events table, the AiEvent model, and the subscriber that records ActiveAI's events."

      class_option :database, type: :string, default: "primary",
                              desc: "Name of the database.yml entry AiEventRecord connects to"

      def create_migration_file
        migration_template "create_active_ai_events.rb.tt", "db/migrate/create_active_ai_events.rb"
      end

      def create_models
        template "ai_event_record.rb.tt", "app/models/ai_event_record.rb"
        template "ai_event.rb.tt", "app/models/ai_event.rb"
      end

      def create_subscriber
        template "active_ai_event_log.rb.tt", "config/initializers/active_ai_event_log.rb"
      end

      private

      def database_name = options[:database]
    end
  end
end
