require_relative "../test_helper"
require_relative "../support/sqlite_database"
require_relative "../support/snapshot_store_contract"

# Runs the shared snapshot-store contract against SqliteSnapshotStore -- the
# same contract InMemorySnapshotStore (test/unit/) and PostgresSnapshotStore
# (test/integration/) run -- plus the SQLite specifics of its table.
class TestSqliteSnapshotStore < Minitest::Test
  cover "DcbEventStore::Snapshots::SqliteSnapshotStore*"

  include SqliteDatabaseHelper
  include SnapshotStoreContract

  def setup
    setup_db
    DcbEventStore::Snapshots::SqliteSnapshotStore::Schema.create!(@db)
    @snapshots = DcbEventStore::Snapshots::SqliteSnapshotStore.new(@db)
  end

  def teardown
    teardown_db
  end

  def test_create_is_idempotent
    DcbEventStore::Snapshots::SqliteSnapshotStore::Schema.create!(@db)

    @snapshots.store("k", position: 1, state: { n: 1 })
    assert_equal 1, @snapshots.fetch("k").position
  end

  def test_drop_removes_the_table
    DcbEventStore::Snapshots::SqliteSnapshotStore::Schema.drop!(@db)

    assert_raises(SQLite3::SQLException) { @snapshots.fetch("k") }
  end

  def test_drop_is_idempotent
    DcbEventStore::Snapshots::SqliteSnapshotStore::Schema.drop!(@db)
    DcbEventStore::Snapshots::SqliteSnapshotStore::Schema.drop!(@db)

    DcbEventStore::Snapshots::SqliteSnapshotStore::Schema.create!(@db)
    assert_nil @snapshots.fetch("k")
  end

  # The state column is JSON text, so what is stored must be readable as JSON
  # by SQLite itself, not just by the Ruby side.
  def test_state_is_stored_as_json_text
    @snapshots.store("k", position: 1, state: { n: [1, true, "x"] })

    stored = @db.execute("SELECT json_extract(state, '$.n[2]') AS v FROM projection_snapshots WHERE key = 'k'")
    assert_equal "x", (stored[0].is_a?(Hash) ? stored[0]["v"] : stored[0][0])
  end

  def test_updated_at_moves_forward_on_a_replacing_write
    @snapshots.store("k", position: 1, state: { n: 1 })
    first = updated_at("k")
    sleep 0.01
    @snapshots.store("k", position: 2, state: { n: 2 })

    assert_operator updated_at("k"), :>, first
  end

  # Unlike the events table the snapshot table is mutable by design: no
  # append-only trigger stands in the way of an UPDATE or a DELETE.
  def test_rows_are_updatable_and_deletable
    @snapshots.store("k", position: 1, state: { n: 1 })

    @db.execute("UPDATE projection_snapshots SET position = 5 WHERE key = 'k'")
    assert_equal 5, @snapshots.fetch("k").position

    @snapshots.delete("k")
    assert_nil @snapshots.fetch("k")
  end

  # The store must not depend on the connection being left in hash mode.
  def test_reads_a_connection_left_in_array_result_mode
    db = SqliteDatabaseHelper.connection(@db_path)
    db.results_as_hash = false
    snapshots = DcbEventStore::Snapshots::SqliteSnapshotStore.new(db)

    snapshots.store("k", position: 3, state: { n: 1 })

    entry = snapshots.fetch("k")
    assert_equal 3, entry.position
    assert_equal({ n: 1 }, entry.state)
  ensure
    db&.close
  end

  private

  def updated_at(key)
    row = @db.execute("SELECT updated_at AS u FROM projection_snapshots WHERE key = ?", [key])[0]
    row.is_a?(Hash) ? row["u"] : row[0]
  end
end
