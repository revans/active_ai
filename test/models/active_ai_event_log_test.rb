require "test_helper"
require "support/fake_openai_agent"

ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :active_ai_events, force: true do |t|
    t.string   :name, null: false
    t.string   :run_id, null: false
    t.string   :span_id
    t.string   :parent_span_id
    t.string   :request_id
    t.string   :job_id
    t.string   :caller_type
    t.string   :caller_name
    t.datetime :started_at, null: false, precision: 6
    t.datetime :finished_at, null: false, precision: 6
    t.float    :duration_ms
    t.text     :error
    t.json     :payload, null: false
    t.datetime :created_at, null: false
  end
end
ActiveRecord::Schema.verbose = true

class ActiveAIEventLogTest < ActiveSupport::TestCase
  # The generated AIEvent runs on its own connection pool; the in-memory test database
  # cannot be shared across pools, so this one uses the default connection.
  class Event < ActiveRecord::Base
    include ActiveAI::EventLog
    self.table_name = "active_ai_events"
  end

  class RedactingEvent < Event
    def self.filter_payload(_name, payload) = payload.except(:input)
  end

  class LogTool < ActiveAI::Tool::Base
    tool_name "log_tool"
    description "Returns a fixed answer"
    def call(**) = "ok"
  end

  class BrokenTool < ActiveAI::Tool::Base
    tool_name "broken_tool"
    description "Raises"
    def call(**) = raise("disk full")
  end

  setup { Event.delete_all }

  def recording(model = Event, &)
    subscriber = ActiveSupport::Notifications.subscribe(/\.active_ai\z/) { |event| model.record(event) }
    yield
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  test "stores each event with its run, span and timing, and finds the run again" do
    recording { ActiveAI::Instrumentation.with_run(run_id: "run-7") { LogTool.new.call(text: "hi") } }

    event = Event.for_run("run-7").sole
    assert_equal "tool_call", event.name
    assert event.span_id.present?
    assert_equal({ "text" => "hi" }, event.payload["input"])
    assert_equal "ok", event.payload["result"]
    assert_in_delta Time.current, event.started_at, 5
    assert_operator event.finished_at, :>=, event.started_at
  end

  test "an event that raised stores the error, not the exception object" do
    recording { assert_raises(RuntimeError) { BrokenTool.new.call } }

    event = Event.sole
    assert_equal "RuntimeError: disk full", event.error
    assert_not event.payload.key?("exception_object")
  end

  test "payload values become plain JSON data" do
    shop = Struct.new(:id)
    stored = Event.storable(context: :staff, at: Time.utc(2026, 10, 28), nested: [{ kind: :x }], other: shop.new(4))

    assert_equal "staff", stored["context"]
    assert_equal "2026-10-28T00:00:00.000Z", stored["at"]
    assert_equal [{ "kind" => "x" }], stored["nested"]
    assert_kind_of String, stored["other"].to_s
  end

  test "a record becomes its GlobalID" do
    record = Event.create!(name: "x", run_id: "r", started_at: Time.current, finished_at: Time.current, payload: {})

    assert_match %r{\Agid://}, Event.storable(record)
  end

  test "filter_payload drops what must not be stored" do
    recording(RedactingEvent) { LogTool.new.call(text: "secret") }

    assert_not Event.sole.payload.key?("input")
  end

  test "request_for rebuilds exactly what each provider call was sent, from requests that each stored only what was new" do
    agent, sent = FakeOpenAIAgent.build(FakeOpenAIAgent.tool_then_answer)
    recording { agent.complete }

    spans = Event.where(name: "agent_request").order(:started_at, :id).map(&:span_id)
    assert_equal 2, spans.size
    spans.zip(sent).each do |span, messages|
      request = Event.request_for(span)
      assert_equal JSON.parse(messages.to_json), request["messages"]
      assert_equal "lookup", request["tools"].first["name"]
    end
  end

  test "request_for refuses to rebuild a request with a missing piece" do
    agent, _sent = FakeOpenAIAgent.build(FakeOpenAIAgent.tool_then_answer)
    recording { agent.complete }
    first, second = Event.where(name: "agent_request").order(:started_at, :id).to_a

    first.destroy
    assert_nil Event.request_for(second.span_id)
  end

  test "prune deletes events older than the window and keeps the rest" do
    old    = Event.create!(name: "x", run_id: "old", started_at: 100.days.ago, finished_at: 100.days.ago, payload: {})
    recent = Event.create!(name: "x", run_id: "new", started_at: 1.day.ago, finished_at: 1.day.ago, payload: {})

    assert_equal 1, Event.prune(older_than: 90.days)
    assert_equal [recent.id], Event.pluck(:id)
    assert_not Event.exists?(old.id)
  end

  test "a failed insert never raises into the AI call" do
    failing = Class.new(Event) { def self.create!(**) = raise(ActiveRecord::StatementInvalid, "no table") }

    recording(failing) { assert_equal "ok", LogTool.new.call(text: "hi") }
  end
end
