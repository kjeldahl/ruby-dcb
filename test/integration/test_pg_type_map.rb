require_relative "../test_helper"
require_relative "../support/postgres_database"

# The result type map PostgresStore installs on its connection: TIMESTAMPTZ
# comes back as a Time the driver built, which is what spares the row mapper
# a parse per row, while every other column stays the text RowMapper and
# Dialect expect. Complements the pure decode_timestamp assertions in
# test_postgres_dialect.
class TestPgTypeMap < Minitest::Test
  include PostgresDatabaseHelper

  def setup
    setup_db
  end

  def teardown
    teardown_db
  end

  def stored_row
    @store.append([DcbEventStore::Event.new(type: "A", data: { n: 1 }, tags: ["t:1"])])
    @conn.exec("SELECT * FROM events LIMIT 1")[0]
  end

  def test_created_at_comes_back_as_a_time
    assert_kind_of Time, stored_row["created_at"]
  end

  def test_every_other_column_stays_text
    row = stored_row

    %w[sequence_position event_id type data tags schema_version].each do |column|
      assert_kind_of String, row[column], "#{column} should still be text"
    end
  end

  def test_the_store_reads_the_driver_built_time_unchanged
    appended = @store.append([DcbEventStore::Event.new(type: "A")])
    raw = @conn.exec("SELECT created_at FROM events LIMIT 1")[0]["created_at"]

    read = @store.read(DcbEventStore::Query.all).first.created_at

    assert_equal raw, read
    assert_equal raw.utc_offset, read.utc_offset
    assert_equal raw.nsec, read.nsec
    assert_equal appended[0].created_at, read
  end

  def test_microsecond_precision_survives
    # PostgreSQL stores TIMESTAMPTZ to the microsecond; the decoder must not
    # round it away, or events appended in the same millisecond would stop
    # being distinguishable by time.
    @conn.exec("INSERT INTO events (type, created_at) VALUES ('A', '2026-06-13 22:00:00.123456+00')")

    created_at = @store.read(DcbEventStore::Query.all).first.created_at

    assert_equal 123_456, created_at.usec
  end

  def test_a_store_built_on_a_second_connection_installs_its_own_map
    # Every store owns its connection, so each one has to set the map up.
    second = PostgresDatabaseHelper.connection
    DcbEventStore::PostgresStore.new(second)

    assert_kind_of Time, second.exec("SELECT now() AS t")[0]["t"]
  ensure
    second&.close
  end
end
