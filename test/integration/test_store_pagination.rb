require_relative "../test_helper"
require_relative "../support/database"

# Exercises Store#read pagination across multiple batches. Store reads in
# batches of BATCH_SIZE (1000) using keyset pagination on sequence_position,
# so a result set larger than one batch must come back complete, in order,
# and without duplicates or gaps at the batch boundary.
class TestStorePagination < Minitest::Test
  cover "DcbEventStore::Store#read"
  cover "DcbEventStore::Store#read_from"

  include DatabaseHelper

  BATCH_SIZE = DcbEventStore::Store::BATCH_SIZE

  def setup
    setup_db
  end

  def teardown
    teardown_db
  end

  def insert_events(count, type: "A")
    @conn.exec_params(
      <<~SQL,
        INSERT INTO events (event_id, type, data, tags)
        SELECT gen_random_uuid(), $1, '{}'::jsonb, '{}'::text[]
        FROM generate_series(1, $2)
      SQL
      [type, count]
    )
  end

  def test_read_returns_all_rows_across_batch_boundary
    total = (BATCH_SIZE * 2) + 50
    insert_events(total)

    positions = @store.read(DcbEventStore::Query.all).map(&:sequence_position)

    assert_equal total, positions.size
    assert_equal positions.sort, positions
    assert_equal positions.uniq, positions
  end

  def test_read_from_paginates_across_batch_boundary
    insert_events(BATCH_SIZE + 25)

    after = 10
    positions = @store.read_from(DcbEventStore::Query.all, after: after).map(&:sequence_position)

    assert_equal (BATCH_SIZE + 25) - after, positions.size
    assert(positions.all? { |p| p > after })
    assert_equal positions.sort, positions
    assert_equal positions.uniq, positions
  end
end
