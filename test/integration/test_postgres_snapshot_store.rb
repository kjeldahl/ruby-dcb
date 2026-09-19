require_relative "../test_helper"
require_relative "../support/postgres_database"
require_relative "../support/snapshot_store_contract"

# Runs the shared snapshot-store contract against PostgresSnapshotStore -- the
# same contract InMemorySnapshotStore (test/unit/) and SqliteSnapshotStore
# (test/sqlite/) run -- plus the PostgreSQL specifics of its table.
class TestPostgresSnapshotStore < Minitest::Test
  cover "DcbEventStore::Snapshots::PostgresSnapshotStore*"

  include PostgresDatabaseHelper
  include SnapshotStoreContract

  def setup
    setup_db
    DcbEventStore::Snapshots::PostgresSnapshotStore::Schema.create!(@conn)
    @snapshots = DcbEventStore::Snapshots::PostgresSnapshotStore.new(@conn)
    @snapshots.clear
  end

  def teardown
    teardown_db
  end

  def test_create_is_idempotent
    DcbEventStore::Snapshots::PostgresSnapshotStore::Schema.create!(@conn)

    @snapshots.store("k", position: 1, state: { n: 1 })
    assert_equal 1, @snapshots.fetch("k").position
  end

  def test_drop_removes_the_table_and_create_brings_it_back
    DcbEventStore::Snapshots::PostgresSnapshotStore::Schema.drop!(@conn)

    assert_raises(PG::UndefinedTable) { @snapshots.fetch("k") }

    DcbEventStore::Snapshots::PostgresSnapshotStore::Schema.create!(@conn)
    assert_nil @snapshots.fetch("k")
  end

  def test_drop_is_idempotent
    DcbEventStore::Snapshots::PostgresSnapshotStore::Schema.drop!(@conn)
    DcbEventStore::Snapshots::PostgresSnapshotStore::Schema.drop!(@conn)
    DcbEventStore::Snapshots::PostgresSnapshotStore::Schema.create!(@conn)

    assert_nil @snapshots.fetch("k")
  end

  # The state column is JSONB, so PostgreSQL itself must be able to read into
  # the stored state, not just the Ruby side.
  def test_state_is_stored_as_jsonb
    @snapshots.store("k", position: 1, state: { n: [1, true, "x"] })

    value = @conn.exec("SELECT state #>> '{n,2}' AS v FROM projection_snapshots WHERE key = 'k'")[0]["v"]
    assert_equal "x", value

    type = @conn.exec("SELECT jsonb_typeof(state) AS t FROM projection_snapshots WHERE key = 'k'")[0]["t"]
    assert_equal "object", type
  end

  def test_position_is_read_back_as_an_integer
    @snapshots.store("k", position: 9_223_372_036_854_775_806, state: { n: 1 })

    assert_equal 9_223_372_036_854_775_806, @snapshots.fetch("k").position
  end

  def test_updated_at_moves_forward_on_a_replacing_write
    @snapshots.store("k", position: 1, state: { n: 1 })
    first = updated_at("k")
    @snapshots.store("k", position: 2, state: { n: 2 })

    assert_operator updated_at("k"), :>=, first
  end

  # The forward-only guard is in the ON CONFLICT clause, so it also holds for
  # a second connection writing the same key.
  def test_forward_only_upsert_holds_across_connections
    other = PostgresDatabaseHelper.connection
    writer = DcbEventStore::Snapshots::PostgresSnapshotStore.new(other)

    @snapshots.store("k", position: 9, state: { n: 9 })
    writer.store("k", position: 4, state: { n: 4 })

    assert_equal 9, @snapshots.fetch("k").position
    assert_equal({ n: 9 }, writer.fetch("k").state)
  ensure
    other&.close
  end

  private

  def updated_at(key)
    @conn.exec_params("SELECT updated_at FROM projection_snapshots WHERE key = $1", [key])[0]["updated_at"]
  end
end
