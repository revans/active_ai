require "rails/generators"
require "rails/generators/migration"

module ActiveAI
  module Memory
    # Generates all migrations and app scaffold for the ActiveAI Memory system.
    #
    # Usage:
    #   rails generate active_ai:memory:install
    #   rails generate active_ai:memory:install --vector=pgvector
    #
    # The --vector=pgvector flag adds the pgvector extension enable migration
    # and the vector column to active_ai_memory_embeddings.
    class InstallGenerator < Rails::Generators::Base
      namespace "active_ai:memory:install"
      include Rails::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      class_option :vector, type: :string, default: nil,
                            desc: "Vector store backend (e.g. pgvector)"

      def self.next_migration_number(dirname)
        next_migration_number = current_migration_number(dirname) + 1
        ActiveRecord::Migration.next_migration_number(next_migration_number)
      end

      def create_migration_files
        migration_template "migrations/create_active_ai_memories.rb.tt",
                           "db/migrate/create_active_ai_memories.rb"
        migration_template "migrations/create_active_ai_memory_embeddings.rb.tt",
                           "db/migrate/create_active_ai_memory_embeddings.rb"
        migration_template "migrations/create_active_ai_memory_correlations.rb.tt",
                           "db/migrate/create_active_ai_memory_correlations.rb"
        migration_template "migrations/create_active_ai_memory_flags.rb.tt",
                           "db/migrate/create_active_ai_memory_flags.rb"

        if vector_store == "pgvector"
          migration_template "migrations/enable_pgvector.rb.tt",
                             "db/migrate/enable_pgvector.rb"
        end
      end

      def create_application_memory
        template "application_memory.rb.tt", "app/ai/memory/application_memory.rb"
      end

      def create_memory_agents
        %w[embed tier consolidation].each do |name|
          template "agents/active_ai_memory_#{name}_agent.rb.tt",
                   "app/ai/agents/active_ai_memory_#{name}_agent.rb"
        end
      end

      def create_memory_jobs
        %w[embed persist tier consolidate].each do |name|
          template "jobs/active_ai_memory_#{name}_job.rb.tt",
                   "app/jobs/active_ai_memory_#{name}_job.rb"
        end
      end

      def add_neighbor_gem
        return unless vector_store == "pgvector"
        # neighbor teaches Rails the vector column type and provides
        # has_neighbors scopes for nearest-neighbor queries.
        gem "neighbor" unless gemfile_includes?("neighbor")
      end

      def show_readme
        readme "README.tt" if behavior == :invoke
      end

      private

      def vector_store
        options[:vector]
      end

      def gemfile_includes?(gem_name)
        gemfile = File.read(destination_root.join("Gemfile")) rescue ""
        gemfile.match?(/^\s*gem\s+['"]#{Regexp.escape(gem_name)}['"]/)
      end
    end
  end
end
