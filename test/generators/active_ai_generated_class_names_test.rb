require "test_helper"
require "tmpdir"
require "rails/generators/test_case"
require "generators/active_ai/event_log/event_log_generator"
require "generators/active_ai/memory/install_generator"
require "generators/active_ai/credentials/credentials_generator"

# ActiveAI registers the "AI" acronym, so an app expects ai_event.rb to define AIEvent and
# create_active_ai_events.rb to define CreateActiveAIEvents. Every file a generator writes
# under a fixed name must define the class Zeitwerk and the migration loader will look for.
class ActiveAIGeneratedClassNamesTest < Rails::Generators::TestCase
  destination File.join(Dir.tmpdir, "active_ai_class_name_tests_#{Process.pid}")
  setup :prepare_destination

  GENERATORS = {
    ActiveAI::Generators::EventLogGenerator   => [%w[--link-to=messages], %w[--timescaledb]],
    ActiveAI::Memory::InstallGenerator        => [%w[], %w[--vector=pgvector]],
    ActiveAI::Generators::CredentialsGenerator => [%w[]]
  }.freeze

  GENERATORS.each do |generator, option_sets|
    option_sets.each do |options|
      test "#{generator.name} #{options.join(' ')} defines the class each file name expects" do
        self.class.tests generator
        prepare_destination
        File.write(File.join(destination_root, "Gemfile"), "source \"https://rubygems.org\"\n")
        run_generator options

        files = Dir[File.join(destination_root, "{app,db,config}/**/*.rb")].reject { |path| path.include?("/initializers/") }
        assert_not_empty files
        files.each do |path|
          expected = File.basename(path, ".rb").sub(/\A\d+_/, "").camelize
          assert_match(/^class (\w+::)*#{expected}\b/, File.read(path), "#{path.delete_prefix(destination_root)} must define #{expected}")
        end
      end
    end
  end
end
