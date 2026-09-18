require_relative "../test_helper"
require_relative "../support/postgres_database"

# The events table is append-only: the schema's triggers must reject updates
# and deletes. PG-specific because it bypasses the store API and asserts on
# the database's own error.
class TestAppendOnly < Minitest::Test
  cover "DcbEventStore::PostgresStore::Schema*"

  include PostgresDatabaseHelper

  def setup
    setup_db
  end

  def teardown
    teardown_db
  end

  def test_update_raises
    @store.append([DcbEventStore::Event.new(type: "A")])
    assert_raises(PG::RaiseException) do
      @conn.exec("UPDATE events SET type = 'B' WHERE sequence_position = 1")
    end
  end

  def test_delete_raises
    @store.append([DcbEventStore::Event.new(type: "A")])
    assert_raises(PG::RaiseException) do
      @conn.exec("DELETE FROM events WHERE sequence_position = 1")
    end
  end
end
