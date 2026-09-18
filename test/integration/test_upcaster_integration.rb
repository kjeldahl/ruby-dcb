require_relative "../test_helper"
require_relative "../support/postgres_database"
require_relative "../support/upcaster_contract"

# Runs the shared Upcaster contract against PostgresStore; TestInMemoryStore
# runs the identical contract against InMemoryStore.
class TestUpcasterIntegration < Minitest::Test
  cover "DcbEventStore::Upcaster*"

  include PostgresDatabaseHelper
  include UpcasterContract

  def setup
    setup_db
  end

  def teardown
    teardown_db
  end
end
