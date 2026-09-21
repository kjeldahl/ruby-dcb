require_relative "../test_helper"
require_relative "../support/postgres_database"
require_relative "../support/namespace_contract"
require "concurrent"

# Namespaces on PostgreSQL: the shared contract, plus the prefixed tables,
# the trigger message naming the table, and a subscriber on its own NOTIFY
# channel that another namespace's appends never wake.
class TestPostgresNamespace < Minitest::Test
  include PostgresDatabaseHelper
  include NamespaceContract

  NAMESPACES = %w[billing shipping].freeze

  def setup
    setup_db
    NAMESPACES.each { |name| DcbEventStore::PostgresStore::Schema.drop!(@conn, namespace: name) }
  end

  def teardown
    NAMESPACES.each { |name| DcbEventStore::PostgresStore::Schema.drop!(@conn, namespace: name) }
    teardown_db
  end

  def build_namespaced_store(name)
    DcbEventStore::PostgresStore::Schema.create!(@conn, namespace: name)
    DcbEventStore::PostgresStore.new(@conn, namespace: name)
  end

  def build_namespaced_snapshot_store(name)
    DcbEventStore::PostgresStore::Schema.create!(@conn, namespace: name)
    DcbEventStore::Snapshots::PostgresSnapshotStore.new(@conn, namespace: name)
  end

  def test_schema_installs_prefixed_tables_and_indexes
    build_namespaced_store("billing")

    assert_equal %w[billing_events billing_projection_snapshots], table_names("billing_%")
    assert_equal %w[idx_billing_events_correlation_id idx_billing_events_event_id
                    idx_billing_events_tags idx_billing_events_type],
                 index_names("billing_events")
  end

  def test_namespaced_table_is_append_only_and_the_message_names_it
    billing = build_namespaced_store("billing")
    billing.append([event])

    error = assert_raises(PG::RaiseException) { @conn.exec("DELETE FROM billing_events") }
    assert_includes error.message, "billing_events table is append-only: DELETE not allowed"

    @store.append([event])
    error = assert_raises(PG::RaiseException) { @conn.exec("UPDATE events SET type = 'B'") }
    assert_includes error.message, "events table is append-only: UPDATE not allowed"
  end

  def test_drop_removes_only_that_namespace_and_keeps_the_shared_functions
    build_namespaced_store("billing")
    build_namespaced_store("shipping")

    DcbEventStore::PostgresStore::Schema.drop!(@conn, namespace: "billing")

    assert_empty table_names("billing_%")
    assert_equal %w[shipping_events shipping_projection_snapshots], table_names("shipping_%")
    assert_equal 1, @store.append([event]).size, "the default namespace still appends (lock function intact)"
  end

  def test_create_sql_and_drop_sql_default_to_the_default_namespace
    assert_includes DcbEventStore::PostgresStore::Schema.create_sql, "CREATE TABLE IF NOT EXISTS events ("
    assert_includes DcbEventStore::PostgresStore::Schema.drop_sql, "DROP TABLE IF EXISTS events CASCADE;"
    assert_includes DcbEventStore::PostgresStore::Schema.create_sql("billing"),
                    "CREATE TRIGGER enforce_append_only\n  BEFORE UPDATE OR DELETE ON billing_events"
  end

  # The subscriber listens on billing_events_appended: the default
  # namespace's NOTIFY goes to events_appended and does not wake it at all,
  # which the notification count shows.
  def test_subscribe_listens_on_its_own_channel
    build_namespaced_store("billing")
    received = []
    wakeups = Concurrent::AtomicFixnum.new(0)
    subscriber = Thread.new do
      conn = PostgresDatabaseHelper.connection
      store = DcbEventStore::PostgresStore.new(conn, namespace: "billing")
      store.singleton_class.prepend(Module.new do
        define_method(:wait_for_append) do
          super()
          wakeups.increment
        end
      end)
      store.subscribe(DcbEventStore::Query.all, after: 0) do |e|
        received << e
        break if received.size >= 1
      end
    ensure
      conn&.close
    end
    sleep 0.2

    @store.append([event("Default")])
    sleep 0.2
    assert_equal 0, wakeups.value, "a default-namespace append woke a billing subscriber"

    build_namespaced_store("billing").append([event("Billed")])
    subscriber.join(5)

    assert_equal 1, wakeups.value
    assert_equal ["Billed"], received.map(&:type)
  end

  private

  def table_names(pattern)
    @conn.exec_params("SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' " \
                      "AND table_name LIKE $1 ORDER BY table_name", [pattern]).map { |row| row["table_name"] }
  end

  def index_names(table)
    @conn.exec_params("SELECT indexname FROM pg_indexes WHERE tablename = $1 AND indexname LIKE 'idx_%' " \
                      "ORDER BY indexname", [table]).map { |row| row["indexname"] }
  end
end
