require_relative "../test_helper"
require_relative "../support/postgres_database"
require "dcb_event_store/web/read_model"

class TestWebReadModel < Minitest::Test
  cover "DcbEventStore::Web::ReadModel*"

  include PostgresDatabaseHelper

  def setup
    setup_db
    # The store owns @conn; the read model gets a plain connection of its own.
    @read_conn = PostgresDatabaseHelper.connection
    @read = DcbEventStore::Web::ReadModel.new(@read_conn)
    @read_conn.exec("TRUNCATE projection_snapshots")
  end

  def teardown
    @read_conn&.close
    teardown_db
  end

  def event(type, data: {}, tags: [])
    DcbEventStore::Event.new(type: type, data: data, tags: tags)
  end

  def seed(*types)
    @store.append(types.map { |t| event(t) })
  end

  # --- count ---

  def test_count_empty
    assert_equal 0, @read.count
  end

  def test_count_all
    seed("A", "B", "C")
    assert_equal 3, @read.count
  end

  def test_count_filtered_by_type
    seed("A", "B", "A")
    query = DcbEventStore::Query.new(DcbEventStore::QueryItem.new(event_types: ["A"]))
    assert_equal 2, @read.count(query)
  end

  # --- head_position ---

  def test_head_position_nil_when_empty
    assert_nil @read.head_position
  end

  def test_head_position_is_max_sequence
    seed("A", "B", "C")
    assert_equal 3, @read.head_position
  end

  # --- page (newest first) ---

  def test_page_returns_newest_first
    seed("A", "B", "C")
    positions = @read.page(limit: 10).map(&:sequence_position)
    assert_equal [3, 2, 1], positions
  end

  def test_page_respects_limit_and_offset
    seed("A", "B", "C", "D", "E")
    page = @read.page(limit: 2, offset: 2)
    assert_equal [3, 2], page.map(&:sequence_position)
  end

  def test_page_returns_sequenced_events
    seed("A")
    e = @read.page(limit: 1).first
    assert_instance_of DcbEventStore::SequencedEvent, e
    assert_equal "A", e.type
  end

  def test_page_filtered_by_query
    seed("A", "B", "A")
    query = DcbEventStore::Query.new(DcbEventStore::QueryItem.new(event_types: ["A"]))
    assert_equal %w[A A], @read.page(query: query, limit: 10).map(&:type)
  end

  # --- event_types ---

  def test_event_types_distinct_sorted
    seed("Beta", "Alpha", "Beta")
    assert_equal %w[Alpha Beta], @read.event_types
  end

  def test_event_types_empty
    assert_empty @read.event_types
  end

  # --- find ---

  def test_find_by_position
    seed("A", "B")
    e = @read.find(2)
    assert_equal "B", e.type
    assert_equal 2, e.sequence_position
  end

  def test_find_missing_returns_nil
    assert_nil @read.find(999)
  end

  # --- namespaces ---

  def in_namespace(name)
    DcbEventStore::PostgresStore::Schema.create!(@read_conn, namespace: name)
    store = DcbEventStore::PostgresStore.new(PostgresDatabaseHelper.connection, namespace: name)
    [store, DcbEventStore::Web::ReadModel.new(@read_conn, namespace: name)]
  end

  def drop_namespaces(*names)
    names.each { |n| DcbEventStore::PostgresStore::Schema.drop!(@read_conn, namespace: n) }
  end

  def test_reads_only_its_namespace
    seed("Default")
    store, read = in_namespace("web_billing")
    store.append([event("Billed"), event("Billed")])

    assert_equal 1, @read.count
    assert_equal 2, read.count
    assert_equal 2, read.head_position
    assert_equal %w[Billed], read.event_types
    assert_equal %w[Billed Billed], read.page.map(&:type)
    assert_equal "Billed", read.find(1).type
  ensure
    drop_namespaces("web_billing")
  end

  def test_namespaces_lists_default_and_named
    in_namespace("web_billing")
    in_namespace("web_shipping")
    assert_equal [nil, "web_billing", "web_shipping"], DcbEventStore::Web::ReadModel.namespaces(@read_conn)
  ensure
    drop_namespaces("web_billing", "web_shipping")
  end

  def test_namespaces_ignores_tables_without_the_events_columns
    @read_conn.exec("CREATE TABLE web_other_events (id int)")
    refute_includes DcbEventStore::Web::ReadModel.namespaces(@read_conn), "web_other"
  ensure
    @read_conn.exec("DROP TABLE IF EXISTS web_other_events")
  end

  def test_namespaces_skips_names_that_are_not_valid_namespaces
    long = "web_#{'x' * DcbEventStore::Namespace::MAX_NAME_LENGTH}"
    @read_conn.exec("CREATE TABLE #{long}_events (sequence_position int, event_id int, type int, data int, tags int)")
    refute_includes DcbEventStore::Web::ReadModel.namespaces(@read_conn), long
  ensure
    @read_conn.exec("DROP TABLE IF EXISTS #{long}_events")
  end

  # --- snapshots ---

  def snapshot_store(namespace: nil)
    DcbEventStore::Snapshots::PostgresSnapshotStore.new(PostgresDatabaseHelper.connection, namespace: namespace)
  end

  def test_snapshots_present_in_default_schema
    assert_predicate @read, :snapshots?
  end

  def test_snapshots_absent_without_table
    @read_conn.exec("DROP TABLE projection_snapshots")
    refute_predicate @read, :snapshots?
  ensure
    DcbEventStore::PostgresStore::Schema.create!(@read_conn)
  end

  def test_snapshot_page_lists_without_state
    @read_conn.exec("TRUNCATE projection_snapshots")
    store = snapshot_store
    store.store("a/v1/x", position: 3, state: { n: 1 })
    store.store("b/v1/y", position: 5, state: { n: 2 })

    records = @read.snapshot_page
    assert_equal %w[b/v1/y a/v1/x], records.map(&:key)
    assert_equal [5, 3], records.map(&:position)
    assert(records.all? { |r| r.state.nil? })
    assert_instance_of Time, records.first.updated_at
  end

  def test_snapshot_page_filters_by_key_substring_and_pages
    @read_conn.exec("TRUNCATE projection_snapshots")
    store = snapshot_store
    %w[a/v1/1 a/v1/2 a/v1/3 b/v1/1].each_with_index { |k, i| store.store(k, position: i + 1, state: {}) }

    assert_equal 3, @read.snapshot_count(match: "a/v1")
    assert_equal 4, @read.snapshot_count
    assert_equal 1, @read.snapshot_page(match: "a/v1", limit: 1, offset: 2).size
    assert_equal ["b/v1/1"], @read.snapshot_page(match: "b/", limit: 10).map(&:key)
  end

  def test_snapshot_match_is_literal
    @read_conn.exec("TRUNCATE projection_snapshots")
    snapshot_store.store("a%b/v1/1", position: 1, state: {})
    snapshot_store.store("axb/v1/1", position: 2, state: {})
    assert_equal ["a%b/v1/1"], @read.snapshot_page(match: "a%b").map(&:key)
  end

  def test_find_snapshot_includes_state
    @read_conn.exec("TRUNCATE projection_snapshots")
    snapshot_store.store("a/v1/x", position: 3, state: { n: 1, tags: %w[a b] })

    record = @read.find_snapshot("a/v1/x")
    assert_equal 3, record.position
    assert_equal({ n: 1, tags: %w[a b] }, record.state)
  end

  def test_find_snapshot_missing_returns_nil
    assert_nil @read.find_snapshot("nope")
  end

  def test_snapshots_are_per_namespace
    _store, read = in_namespace("web_billing")
    snapshot_store(namespace: "web_billing").store("web_billing/a/v1/x", position: 1, state: {})

    assert_equal ["web_billing/a/v1/x"], read.snapshot_page.map(&:key)
    assert_empty @read.snapshot_page
  ensure
    drop_namespaces("web_billing")
  end
end
