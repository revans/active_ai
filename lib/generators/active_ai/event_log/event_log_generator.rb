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

      class_option :database,    type: :string,  default: "primary",
                                 desc: "Name of the database.yml entry AiEventRecord connects to"
      class_option :retain_days, type: :numeric, default: 90,
                                 desc: "Days ActiveAiEventPruneJob keeps events for"
      class_option :link_to,     type: :string,  default: nil,
                                 desc: "Your own table (e.g. messages) to add an ai_run_id column to"

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

      def create_prune_job
        template "active_ai_event_prune_job.rb.tt", "app/jobs/active_ai_event_prune_job.rb"
      end

      def create_link_migration
        return unless link_table

        migration_template "add_ai_run_id.rb.tt", "db/migrate/add_ai_run_id_to_#{link_table}.rb"
      end

      def show_next_steps
        return unless behavior == :invoke

        say "\nSchedule the prune job, e.g. in config/recurring.yml (Solid Queue):", :green
        say "  prune_active_ai_events:\n    class: ActiveAiEventPruneJob\n    schedule: every day at 3am"
        say "Save agent.run_id into #{link_table}.ai_run_id where you store the message." if link_table
      end

      private

      def database_name = options[:database]
      def retain_days   = options[:retain_days].to_i
      def link_table    = options[:link_to].presence&.underscore&.pluralize
    end
  end
end
