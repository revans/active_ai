require "rails/generators"
require "rails/generators/active_record"

module ActiveAI
  module Generators
    class CredentialsGenerator < Rails::Generators::Base
      namespace "active_ai:credentials"
      include ActiveRecord::Generators::Migration
      source_root File.expand_path("templates", __dir__)
      desc "Creates the ai_credentials migration for storing provider and tool API keys."

      def create_migration
        migration_template "create_ai_credentials.rb.tt",
                           "db/migrate/create_ai_credentials.rb"
      end
    end
  end
end
