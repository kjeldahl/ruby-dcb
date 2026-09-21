require_relative "../test_helper"
require_relative "../support/sqlite_database"
require_relative "../support/namespace_contract"

# Namespaces on SQLite: the shared contract, plus what the file holds
# (prefixed tables and triggers) and a polling subscriber that wakes on any
# commit to the file but reads only its own namespace.
class TestSqliteNamespace < Minitest::Test
  cover "DcbEventStore::SqliteStore*"
  cover "DcbEventStore::SqliteStore::Schema*"

  include SqliteDatabaseHelper
  include NamespaceContract

  def setup
    setup_db
    @extra_dbs = []
  end

  def teardown
    @extra_dbs.each(&:close)
    teardown_db
  end

  def build_namespaced_store(name)
    DcbEventStore::SqliteStore::Schema.create!(@db, namespace: name)
    DcbEventStore::SqliteStore.new(@db, namespace: name)
  end

  def build_namespaced_snapshot_store(name)
    DcbEventStore::SqliteStore::Schema.create!(@db, namespace: name)
    DcbEventStore::Snapshots::SqliteSnapshotStore.new(@db, namespace: name)
  end

  def test_schema_installs_prefixed_tables_and_triggers
    build_namespaced_store("billing")

    assert_equal %w[billing_event_tags billing_events billing_projection_snapshots],
                 names("table", "billing_%")
    assert_equal %w[billing_event_tags_no_delete billing_event_tags_no_update
                    billing_events_no_delete billing_events_no_update],
                 names("trigger", "billing_%")
    assert_equal %w[idx_billing_events_correlation_id idx_billing_events_type],
                 names("index", "idx_billing_%")
  end

  def test_namespaced_tables_are_append_only
    billing = build_namespaced_store("billing")
    billing.append([event])

    error = assert_raises(SQLite3::ConstraintException) { @db.execute("DELETE FROM billing_events") }
    assert_equal "billing_events table is append-only: DELETE not allowed", error.message

    error = assert_raises(SQLite3::ConstraintException) { @db.execute("UPDATE billing_event_tags SET tag = 'x'") }
    assert_equal "billing_event_tags table is append-only: UPDATE not allowed", error.message
  end

  def test_drop_removes_only_that_namespace
    build_namespaced_store("billing")
    build_namespaced_store("shipping")

    DcbEventStore::SqliteStore::Schema.drop!(@db, namespace: "billing")

    assert_empty names("table", "billing_%")
    assert_equal 3, names("table", "shipping_%").size
    assert_equal %w[event_tags events projection_snapshots], names("table", "%") - names("table", "shipping_%")
  end

  def test_create_sql_and_drop_sql_default_to_the_default_namespace
    assert_includes DcbEventStore::SqliteStore::Schema.create_sql, "CREATE TABLE IF NOT EXISTS events ("
    assert_includes DcbEventStore::SqliteStore::Schema.drop_sql, "DROP TABLE IF EXISTS events;"
    assert_includes DcbEventStore::SqliteStore::Schema.create_sql("billing"), "REFERENCES billing_events("
  end

  # The poll wakes on the default namespace's commit too, and reads nothing
  # from it; only the billing append is delivered.
  def test_subscribe_delivers_only_its_own_namespace
    build_namespaced_store("billing")
    received = []
    subscriber = subscribe_in_thread("billing") do |e|
      received << e
      received.size >= 1
    end

    @store.append([event("Default")])
    sleep 0.1
    build_namespaced_store("billing").append([event("Billed")])

    subscriber.join(5)
    assert_equal ["Billed"], received.map(&:type)
    assert_equal 1, received[0].sequence_position
  end

  private

  def names(type, pattern)
    @db.execute("SELECT name FROM sqlite_master WHERE type = ? AND name LIKE ? AND name NOT LIKE 'sqlite_%'",
                [type, pattern]).map { |row| row["name"] }.sort
  end

  def subscribe_in_thread(namespace, &block)
    ready = Queue.new
    thread = Thread.new do
      db = SqliteDatabaseHelper.connection(@db_path)
      store = DcbEventStore::SqliteStore.new(db, poll_interval: 0.02, namespace: namespace)
      store.singleton_class.prepend(Module.new do
        define_method(:listen) do
          super()
          ready << :listening
        end
      end)
      store.subscribe(DcbEventStore::Query.all) { |e| break if block.call(e) }
    ensure
      db&.close
    end
    assert ready.pop(timeout: 5), "subscriber never started listening"
    thread
  end
end
