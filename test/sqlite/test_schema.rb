require_relative "../test_helper"
require_relative "../support/sqlite_database"

# The SQLite schema: creating it is idempotent, dropping it removes both
# tables, the append-only triggers reject updates and deletes on either of
# them, and an append keeps the event_tags index in step with the tags column.
class TestSqliteSchema < Minitest::Test
  cover "DcbEventStore::SqliteStore::Schema*"

  include SqliteDatabaseHelper

  def setup
    setup_db
  end

  def teardown
    teardown_db
  end

  def test_create_is_idempotent
    DcbEventStore::SqliteStore::Schema.create!(@db)

    assert_equal %w[event_tags events projection_snapshots], table_names
  end

  def test_create_leaves_existing_events_in_place
    @store.append([DcbEventStore::Event.new(type: "A", tags: ["t:1"])])

    DcbEventStore::SqliteStore::Schema.create!(@db)

    assert_equal 1, @store.read(DcbEventStore::Query.all).to_a.size
  end

  def test_drop_removes_all_tables
    DcbEventStore::SqliteStore::Schema.drop!(@db)

    assert_empty table_names
  end

  def test_drop_is_idempotent
    DcbEventStore::SqliteStore::Schema.drop!(@db)
    DcbEventStore::SqliteStore::Schema.drop!(@db)

    assert_empty table_names
  end

  def test_configure_sets_the_pragmas_the_store_relies_on
    db = SQLite3::Database.new(@db_path)
    DcbEventStore::SqliteStore::Schema.configure!(db)

    assert_equal "wal", db.get_first_value("PRAGMA journal_mode")
    assert_equal 1, db.get_first_value("PRAGMA foreign_keys")
    assert_equal 1, db.get_first_value("PRAGMA synchronous")
    assert db.results_as_hash
  ensure
    db&.close
  end

  # The configured busy handler is what makes concurrent appends wait for the
  # database's single write lock: with the lock held elsewhere, an append must
  # block until it is released rather than fail on the spot.
  def test_configure_makes_a_connection_wait_for_the_write_lock
    store = DcbEventStore::SqliteStore.new(SqliteDatabaseHelper.connection(@db_path))
    @db.execute("BEGIN IMMEDIATE")

    appender = Thread.new { store.append([DcbEventStore::Event.new(type: "A")]) }
    refute appender.join(0.2), "expected the append to wait for the write lock"

    @db.execute("COMMIT")

    assert appender.join(5), "expected the append to go through once the lock was free"
    assert_equal 1, @store.read(DcbEventStore::Query.all).to_a.size
  ensure
    appender&.kill
  end

  def test_drop_then_create_starts_from_an_empty_store
    @store.append([DcbEventStore::Event.new(type: "A", tags: ["t:1"])])

    DcbEventStore::SqliteStore::Schema.drop!(@db)
    DcbEventStore::SqliteStore::Schema.create!(@db)

    assert_equal %w[event_tags events projection_snapshots], table_names
    assert_empty @store.read(DcbEventStore::Query.all).to_a
    assert_empty tag_rows
    assert_equal 1, @store.append([DcbEventStore::Event.new(type: "B")]).first.sequence_position
  end

  # An in-memory database belongs to the connection that opened it, so it
  # cannot be shared -- but a single connection is a perfectly good store, and
  # the cheapest one for a test suite.
  def test_works_on_an_in_memory_database
    db = SQLite3::Database.new(":memory:")
    DcbEventStore::SqliteStore::Schema.create!(db)
    store = DcbEventStore::SqliteStore.new(db)

    appended = store.append([DcbEventStore::Event.new(type: "A", data: {n: 1}, tags: ["t:1"])])
    read_back = store.read(DcbEventStore::Query.all).to_a

    assert_equal [1], appended.map(&:sequence_position)
    assert_equal ["t:1"], read_back.first.tags
    assert_equal({n: 1}, read_back.first.data)
  ensure
    db&.close
  end

  # create! configures the connection it installs the schema on, so a store
  # built on that same connection needs no further setup.
  def test_create_configures_the_connection
    db = SQLite3::Database.new(File.join(@dir, "fresh.sqlite3"))
    DcbEventStore::SqliteStore::Schema.create!(db)

    assert_equal "wal", db.get_first_value("PRAGMA journal_mode")
    assert db.results_as_hash
  ensure
    db&.close
  end

  # --- append-only triggers ---

  def test_update_of_an_event_raises
    @store.append([DcbEventStore::Event.new(type: "A")])

    error = assert_raises(SQLite3::ConstraintException) do
      @db.execute("UPDATE events SET type = 'B' WHERE sequence_position = 1")
    end
    assert_equal "events table is append-only: UPDATE not allowed", error.message
  end

  def test_delete_of_an_event_raises
    @store.append([DcbEventStore::Event.new(type: "A")])

    error = assert_raises(SQLite3::ConstraintException) do
      @db.execute("DELETE FROM events WHERE sequence_position = 1")
    end
    assert_equal "events table is append-only: DELETE not allowed", error.message
  end

  def test_update_of_a_tag_row_raises
    @store.append([DcbEventStore::Event.new(type: "A", tags: ["t:1"])])

    error = assert_raises(SQLite3::ConstraintException) do
      @db.execute("UPDATE event_tags SET tag = 't:2'")
    end
    assert_equal "event_tags table is append-only: UPDATE not allowed", error.message
  end

  def test_delete_of_a_tag_row_raises
    @store.append([DcbEventStore::Event.new(type: "A", tags: ["t:1"])])

    error = assert_raises(SQLite3::ConstraintException) do
      @db.execute("DELETE FROM event_tags")
    end
    assert_equal "event_tags table is append-only: DELETE not allowed", error.message
  end

  # --- created_at ---

  # Schema DDL before created_at became epoch microseconds. Kept verbatim so
  # the backward-compatibility test below reads what such a database holds.
  LEGACY_EVENTS_SQL = <<~SQL.freeze
    CREATE TABLE events (
      sequence_position INTEGER PRIMARY KEY AUTOINCREMENT,
      event_id          TEXT NOT NULL UNIQUE,
      type              TEXT NOT NULL,
      data              TEXT NOT NULL DEFAULT '{}',
      tags              TEXT NOT NULL DEFAULT '[]',
      causation_id      TEXT,
      correlation_id    TEXT,
      schema_version    INTEGER NOT NULL DEFAULT 1,
      created_at        TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
    );
  SQL

  def test_created_at_is_stored_as_epoch_microseconds
    @store.append([DcbEventStore::Event.new(type: "A")])

    stored = @db.get_first_value("SELECT created_at FROM events")

    assert_kind_of Integer, stored
    assert_equal "INTEGER", column_type("events", "created_at")
  end

  def test_created_at_is_read_back_as_the_time_it_was_stamped
    before = Time.now.utc
    appended = @store.append([DcbEventStore::Event.new(type: "A")])
    after = Time.now.utc

    created_at = @store.read(DcbEventStore::Query.all).first.created_at

    assert_predicate created_at, :utc?
    assert_operator created_at, :>=, before - 1
    assert_operator created_at, :<=, after + 1
    assert_equal appended[0].created_at, created_at
  end

  def test_reads_a_database_whose_created_at_is_still_text
    # An events table created by an earlier version of the gem: created_at is
    # ISO 8601 text, and the store has to go on reading it.
    legacy = File.join(@dir, "legacy.sqlite3")
    db = SQLite3::Database.new(legacy)
    DcbEventStore::SqliteStore::Schema.configure!(db)
    db.execute_batch(LEGACY_EVENTS_SQL)
    db.execute(
      "INSERT INTO events (event_id, type, created_at) VALUES ('evt-1', 'A', '2026-06-13T22:00:00.123Z')"
    )

    event = DcbEventStore::SqliteStore.new(db).read(DcbEventStore::Query.all).first

    assert_equal Time.utc(2026, 6, 13, 22, 0, 0, 123_000), event.created_at
    assert_predicate event.created_at, :utc?
  ensure
    db&.close
  end

  # --- event_tags index ---

  def test_append_writes_one_tag_row_per_tag
    appended = @store.append([
                               DcbEventStore::Event.new(type: "A", tags: ["course:c1", "student:s1"]),
                               DcbEventStore::Event.new(type: "B", tags: ["course:c1"])
                             ])
    first = appended[0].sequence_position
    second = appended[1].sequence_position

    assert_equal [["course:c1", first], ["course:c1", second], ["student:s1", first]], tag_rows
  end

  def test_append_writes_a_repeated_tag_once
    appended = @store.append([DcbEventStore::Event.new(type: "A", tags: %w[dup dup])])

    assert_equal [["dup", appended[0].sequence_position]], tag_rows
  end

  def test_append_writes_no_tag_rows_for_an_untagged_event
    @store.append([DcbEventStore::Event.new(type: "A")])

    assert_empty tag_rows
  end

  # The tags column and the index table are two representations of the same
  # list, so they must agree for every stored event.
  def test_tag_rows_match_the_stored_tags_column
    @store.append([
                    DcbEventStore::Event.new(type: "A", tags: ["course:c1", "student:s1"]),
                    DcbEventStore::Event.new(type: "B", tags: [])
                  ])

    from_column = @db.execute("SELECT sequence_position, tags FROM events").flat_map do |row|
      JSON.parse(row["tags"]).map { |tag| [tag, row["sequence_position"]] }
    end

    assert_equal from_column.sort, tag_rows
  end

  private

  def column_type(table, column)
    @db.execute("SELECT name, type FROM pragma_table_info(?)", [table])
       .find { |row| row["name"] == column }["type"]
  end

  def table_names
    @db.execute("SELECT name FROM sqlite_master WHERE type = 'table' " \
                "AND name IN ('events', 'event_tags', 'projection_snapshots')")
       .map { |row| row["name"] }.sort
  end

  def tag_rows
    @db.execute("SELECT tag, sequence_position FROM event_tags")
       .map { |row| [row["tag"], row["sequence_position"]] }.sort
  end
end
