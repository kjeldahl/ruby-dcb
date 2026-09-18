require_relative "../test_helper"
require_relative "../support/postgres_database"
require_relative "../support/client_contract"

# Runs the shared Client contract against PostgresStore; TestInMemoryStore
# runs the identical contract against InMemoryStore.
class TestClientIntegration < Minitest::Test
  cover "DcbEventStore::Client*"

  include PostgresDatabaseHelper
  include ClientContract

  def setup
    setup_db
  end

  def teardown
    teardown_db
  end
end
