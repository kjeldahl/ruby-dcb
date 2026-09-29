require_relative "../test_helper"
require_relative "../support/postgres_database"
require_relative "../support/concurrent_decide_contract"

class TestConcurrentDecide < Minitest::Test
  include PostgresDatabaseHelper
  include ConcurrentDecideContract

  def setup
    setup_db
  end

  def teardown
    teardown_db
  end

  private

  def with_own_store
    conn = PostgresDatabaseHelper.connection
    yield DcbEventStore::PostgresStore.new(conn)
  ensure
    conn&.close
  end
end
