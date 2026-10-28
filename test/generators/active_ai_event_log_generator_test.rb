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
    assert_migration "db/migrate/create_active_ai_events.rb", /add_index :active_ai_events, \[ :run_id, :started_at \]/
    assert_file "app/models/ai_event_record.rb", /connects_to database: \{ writing: :primary \}/
    assert_file "app/models/ai_event.rb", /class AIEvent < AIEventRecord/, /include ActiveAI::EventLog/
    assert_file "config/initializers/active_ai_event_log.rb", /subscribe\(\/\\\.active_ai\\z\/\)/, /AIEvent\.record\(event\)/
  end

  test "the generated AIEvent keeps a tool's name and arguments but not its result" do
    run_generator

    source = File.read(File.join(destination_root, "app/models/ai_event.rb"))
    filter = Module.new { module_eval(source[/  def self\.filter_payload.*?\n  end\n/m]) }
    stored = filter.filter_payload("tool_call.active_ai", { tool_name: "lookup", input: { q: "x" }, result: "rows" })

    assert_equal({ tool_name: "lookup", input: { q: "x" } }, stored)
    assert_equal({ result: "kept" }, filter.filter_payload("agent_turn.active_ai", { result: "kept" }))
  end

  test "--database points the event connection at another database.yml entry" do
    run_generator %w[--database=logs]

    assert_file "app/models/ai_event_record.rb", /connects_to database: \{ writing: :logs \}/
  end

  test "skips the events that repeat prompts and answers, and prunes after 90 days by default" do
    run_generator

    assert_file "config/initializers/active_ai_event_log.rb", /skipped = %w\[agent_complete agent_stream\]/
    assert_file "app/jobs/active_ai_event_prune_job.rb", /RETAIN = 90\.days/, /AIEvent\.prune/
    assert_no_migration "db/migrate/add_ai_run_id_to_messages.rb"
  end

  test "--timescaledb creates a hypertable: text columns, uuid id, timestamptz, (id, started_at) primary key" do
    run_generator %w[--timescaledb]

    assert_migration "db/migrate/create_active_ai_events.rb" do |migration|
      assert_match(/create_table :active_ai_events, id: false/, migration)
      assert_match(/t\.uuid        :id,\s+null: false, default: -> \{ "gen_random_uuid\(\)" \}/, migration)
      assert_no_match(/t\.string|t\.datetime/, migration)
      assert_match(/t\.timestamptz :started_at/, migration)
      assert_match(/create_hypertable\('active_ai_events', 'started_at', chunk_time_interval => INTERVAL '1 day'\)/, migration)
      assert_match(/ADD PRIMARY KEY \(id, started_at\)/, migration)
      assert_match(/def down\n    drop_table :active_ai_events/, migration)
    end
  end

  test "--chunk-interval sets the hypertable chunk size, and refuses anything but an interval" do
    run_generator %w[--timescaledb --chunk-interval=6\ hours]
    assert_migration "db/migrate/create_active_ai_events.rb", /INTERVAL '6 hours'/

    prepare_destination
    assert_raises(Thor::Error) { run_generator ["--timescaledb", "--chunk-interval=1 day'); DROP TABLE x; --"], debug: true }
  end

  test "--retain-days and --link-to" do
    run_generator %w[--retain-days=30 --link-to=messages]

    assert_file "app/jobs/active_ai_event_prune_job.rb", /RETAIN = 30\.days/
    assert_migration "db/migrate/add_ai_run_id_to_messages.rb",
                     /class AddAIRunIdToMessages/, /add_column :messages, :ai_run_id, :string/, /add_index  :messages, :ai_run_id/
  end

  test "every generated Ruby file is valid Ruby" do
    run_generator %w[--link-to=messages]
    Dir[File.join(destination_root, "{app,config,db}/**/*.rb")].each do |path|
      RubyVM::InstructionSequence.compile_file(path)
    end
  end
end
