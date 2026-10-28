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
      desc "Creates the active_ai_events table, the AIEvent model, and the subscriber that records ActiveAI's events."

      class_option :database,    type: :string,  default: "primary",
                                 desc: "Name of the database.yml entry AIEventRecord connects to"
      class_option :retain_days, type: :numeric, default: 90,
                                 desc: "Days ActiveAIEventPruneJob keeps events for"
      class_option :link_to,     type: :string,  default: nil,
                                 desc: "Your own table (e.g. messages) to add an ai_run_id column to"
      class_option :timescaledb,    type: :boolean, default: false,
                                    desc: "Create active_ai_events as a TimescaleDB hypertable partitioned on started_at"
      class_option :chunk_interval, type: :string,  default: "1 day",
                                    desc: "Hypertable chunk interval, with --timescaledb"

      def create_migration_file
        source = options[:timescaledb] ? "create_active_ai_events_timescaledb.rb.tt" : "create_active_ai_events.rb.tt"
        migration_template source, "db/migrate/create_active_ai_events.rb"
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
        say "  prune_active_ai_events:\n    class: #{prune_job_class}\n    schedule: every day at 3am"
        say "Save agent.run_id into #{link_table}.ai_run_id where you store the message." if link_table
      end

      private

      def database_name = options[:database]

      # ActiveAI registers the "AI" acronym, so Rails expects ai_event.rb to define AIEvent.
      # Derived from the file names rather than written out, so they follow the app's own
      # inflections whatever they are.
      def event_class     = "ai_event".camelize
      def record_class    = "ai_event_record".camelize
      def prune_job_class = "active_ai_event_prune_job".camelize
      def retain_days   = options[:retain_days].to_i
      def link_table    = options[:link_to].presence&.underscore&.pluralize

      def chunk_interval
        interval = options[:chunk_interval].to_s
        unless interval.match?(/\A\d+ (second|minute|hour|day|week|month)s?\z/)
          raise Thor::Error, "--chunk-interval must look like \"1 day\" or \"6 hours\", got #{interval.inspect}"
        end

        interval
      end
    end
  end
end
