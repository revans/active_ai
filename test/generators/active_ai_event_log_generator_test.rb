require "test_helper"
require "tmpdir"
require "rails/generators/test_case"
require "generators/active_ai/event_log/event_log_generator"

# rails generate active_ai:event_log
class ActiveAIEventLogGeneratorTest < Rails::Generators::TestCase
  tests ActiveAI::Generators::EventLogGenerator
  destination File.join(Dir.tmpdir, "active_ai_event_log_generator_tests_#{Process.pid}")
  setup :prepare_destination

  test "creates the table, the models on their own connection, and the subscriber" do
    run_generator

    assert_migration "db/migrate/create_active_ai_events.rb", /create_table :active_ai_events/
    assert_migration "db/migrate/create_active_ai_events.rb", /add_index :active_ai_events, \[:run_id, :started_at\]/
    assert_file "app/models/ai_event_record.rb", /connects_to database: \{ writing: :primary \}/
    assert_file "app/models/ai_event.rb", /class AiEvent < AiEventRecord/, /include ActiveAI::EventLog/
    assert_file "config/initializers/active_ai_event_log.rb", /subscribe\(\/\\\.active_ai\\z\/\)/, /AiEvent\.record\(event\)/
  end

  test "--database points the event connection at another database.yml entry" do
    run_generator %w[--database=logs]

    assert_file "app/models/ai_event_record.rb", /connects_to database: \{ writing: :logs \}/
  end

  test "skips the events that repeat prompts and answers, and prunes after 90 days by default" do
    run_generator

    assert_file "config/initializers/active_ai_event_log.rb", /skipped = %w\[agent_complete agent_stream\]/
    assert_file "app/jobs/active_ai_event_prune_job.rb", /RETAIN = 90\.days/, /AiEvent\.prune/
    assert_no_migration "db/migrate/add_ai_run_id_to_messages.rb"
  end

  test "--retain-days and --link-to" do
    run_generator %w[--retain-days=30 --link-to=messages]

    assert_file "app/jobs/active_ai_event_prune_job.rb", /RETAIN = 30\.days/
    assert_migration "db/migrate/add_ai_run_id_to_messages.rb",
                     /class AddAiRunIdToMessages/, /add_column :messages, :ai_run_id, :string/, /add_index  :messages, :ai_run_id/
  end

  test "every generated Ruby file is valid Ruby" do
    run_generator %w[--link-to=messages]
    Dir[File.join(destination_root, "{app,config,db}/**/*.rb")].each do |path|
      RubyVM::InstructionSequence.compile_file(path)
    end
  end
end
