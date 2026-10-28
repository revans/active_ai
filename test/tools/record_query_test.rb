require "test_helper"

ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :record_query_shops, force: true do |t|
    t.string :name
  end

  create_table :record_query_orders, force: true do |t|
    t.bigint  :shop_id
    t.string  :number
    t.string  :status
    t.string  :secret
    t.date    :placed_on
  end

  create_table :record_query_notes, force: true do |t|
    t.bigint :shop_id
    t.string :body
  end
end
ActiveRecord::Schema.verbose = true

module RecordQueryTest
  class Order < ActiveRecord::Base
    self.table_name = "record_query_orders"
    include ActiveAI::Readable

    scope :shipped, -> { where(status: "shipped") }
    scope :since,   ->(date) { where(placed_on: Date.parse(date)..) }

    def self.every_shop   = unscoped
    def self.order_count  = count
    def self.sneaky_write = (create!(number: "planted"); all)

    ai_readable scopes:     { shipped: "Shipped orders", since: "Placed on or after a date", every_shop: nil,
                              order_count: nil, sneaky_write: nil },
                attributes: %i[number status]
  end

  class Note < ActiveRecord::Base
    self.table_name = "record_query_notes"
    include ActiveAI::Readable
    ai_readable attributes: %i[body]
  end

  class Shop < ActiveRecord::Base
    self.table_name = "record_query_shops"
    include ActiveAI::Readable

    has_many :orders, class_name: "RecordQueryTest::Order", foreign_key: :shop_id
    has_many :notes,  class_name: "RecordQueryTest::Note",  foreign_key: :shop_id

    ai_readable associations: [:orders, { notes: { if: ->(_shop, viewer) { viewer == :staff } } }]
  end
end

class ActiveAI::Tools::RecordQueryTest < ActiveSupport::TestCase
  Shop  = RecordQueryTest::Shop
  Order = RecordQueryTest::Order
  Note  = RecordQueryTest::Note

  setup do
    [Order, Note, Shop].each(&:delete_all)
    @mine   = Shop.create!(name: "Mine")
    @theirs = Shop.create!(name: "Theirs")
    @mine.orders.create!(number: "M-1", status: "shipped", secret: "s1", placed_on: Date.new(2026, 10, 1))
    @mine.orders.create!(number: "M-2", status: "open",    secret: "s2", placed_on: Date.new(2026, 9, 1))
    @theirs.orders.create!(number: "T-1", status: "shipped", secret: "s3", placed_on: Date.new(2026, 10, 2))
    @mine.notes.create!(body: "internal")
  end

  test "a root outside the roots relation is not found, even though it exists" do
    result = call(tool(roots: Shop.where(id: @mine.id)), root_id: @theirs.id.to_s, association: "orders")

    assert_equal({ "error" => "No shop #{@theirs.id}." }, result)
  end

  test "returns only declared attributes of the root's own records" do
    result = call(tool, root_id: @mine.id.to_s, association: "orders")

    assert_equal [{ "number" => "M-1", "status" => "shipped" }, { "number" => "M-2", "status" => "open" }],
                 result["records"].sort_by { |row| row["number"] }
    assert_equal false, result["truncated"]
  end

  test "applies declared scopes in order, with arguments" do
    result = call(tool, root_id: @mine.id.to_s, association: "orders",
                        scopes: [{ "name" => "shipped" }, { "name" => "since", "args" => ["2026-09-15"] }])

    assert_equal ["M-1"], result["records"].map { |row| row["number"] }
  end

  test "a declared scope that calls unscoped still cannot leave the root" do
    result = call(tool, root_id: @mine.id.to_s, association: "orders", scopes: [{ "name" => "every_shop" }])

    assert_equal %w[M-1 M-2], result["records"].map { |row| row["number"] }.sort
  end

  test "refuses an undeclared scope, even one the model defines" do
    Order.define_singleton_method(:all_secrets) { unscoped }
    result = call(tool, root_id: @mine.id.to_s, association: "orders", scopes: [{ "name" => "all_secrets" }])

    assert_match(/not a readable scope/, result["error"])
  end

  test "refuses an undeclared association" do
    assert_match(/not readable/, call(tool, root_id: @mine.id.to_s, association: "secrets")["error"])
  end

  test "an association whose if: fails is hidden from the catalog and refused" do
    customer = tool(context: :customer)

    assert_equal ["orders"], call(customer, root_id: @mine.id.to_s)["associations"].map { |a| a["association"] }
    assert_match(/not readable/, call(customer, root_id: @mine.id.to_s, association: "notes")["error"])
    assert_equal [{ "body" => "internal" }], call(tool(context: :staff), root_id: @mine.id.to_s, association: "notes")["records"]
  end

  test "the catalog lists scopes with descriptions and attributes" do
    orders = call(tool, root_id: @mine.id.to_s)["associations"].find { |a| a["association"] == "orders" }

    assert_includes orders["scopes"], { "name" => "shipped", "description" => "Shipped orders" }
    assert_equal %w[number status], orders["attributes"]
  end

  test "a declared method that writes is stopped and nothing is written" do
    result = call(tool, root_id: @mine.id.to_s, association: "orders", scopes: [{ "name" => "sneaky_write" }])

    assert_match(/only reads/, result["error"])
    assert_not Order.exists?(number: "planted")
  end

  test "a declared method that does not return a relation of the model is a configuration error" do
    assert_raises(ActiveAI::ConfigurationError) do
      tool.call(root_id: @mine.id.to_s, association: "orders", scopes: [{ "name" => "order_count" }])
    end
  end

  test "wrong scope arguments come back as an error the model can correct" do
    result = call(tool, root_id: @mine.id.to_s, association: "orders", scopes: [{ "name" => "since" }])

    assert_match(/\Asince: wrong number of arguments/, result["error"])
  end

  test "limits rows and says when it truncated" do
    result = call(tool(max_limit: 1), root_id: @mine.id.to_s, association: "orders", limit: 50)

    assert_equal 1, result["returned"]
    assert_equal true, result["truncated"]
    assert_equal 2, result["total"], "a truncated read still says exactly how many matched"
  end

  test "total counts the scoped, root-bound records, and is the row count when nothing was cut" do
    3.times { |i| @mine.orders.create!(number: "M-S#{i}", status: "shipped", placed_on: Date.new(2026, 10, 3)) }
    capped = call(tool(max_limit: 2), root_id: @mine.id.to_s, association: "orders", scopes: [{ "name" => "shipped" }])
    whole  = call(tool, root_id: @mine.id.to_s, association: "orders", scopes: [{ "name" => "shipped" }])

    assert_equal [2, 4, true], capped.values_at("returned", "total", "truncated"), "4 of mine are shipped; theirs is not counted"
    assert_equal [4, 4, false], whole.values_at("returned", "total", "truncated")
  end

  test "roots must be a relation" do
    assert_raises(ActiveAI::ConfigurationError) { ActiveAI::Tools::RecordQuery.new(roots: @mine) }
  end

  test "the definition describes the shape of a scope entry" do
    scopes = ActiveAI::Tools::RecordQuery.to_definition[:input_schema][:properties][:scopes]

    assert_equal "array", scopes[:type]
    assert_equal %w[name], scopes[:items][:required]
  end

  test "fires record_query.active_ai with the outcome and context, never the rows" do
    events = capture_queries do
      call(tool, root_id: @mine.id.to_s, association: "orders", scopes: [{ "name" => "shipped" }])
      call(tool, root_id: @mine.id.to_s, association: "secrets")
      call(tool, root_id: @mine.id.to_s)
    end

    read, refused, catalog = events
    assert_equal({ root_class: Shop.name, root_id: @mine.id.to_s, association: "orders", outcome: :read,
                   returned: 1, truncated: false, context: :staff },
                 read.slice(:root_class, :root_id, :association, :outcome, :returned, :truncated, :context))
    assert_equal :refused, refused[:outcome]
    assert_match(/not readable/, refused[:reason])
    assert_equal [:catalog, %w[orders notes]], [catalog[:outcome], catalog[:associations]]
    assert_no_match(/M-1|s1/, events.map(&:inspect).join)
  end

  private

  def capture_queries(&)
    events     = []
    subscriber = ActiveSupport::Notifications.subscribe("record_query.active_ai") { |*, payload| events << payload }
    yield
    events
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def tool(roots: Shop.all, context: :staff, **options)
    ActiveAI::Tools::RecordQuery.new(roots: roots, context: context, **options)
  end

  def call(tool, **inputs)
    JSON.parse(tool.call(**inputs))
  end
end
