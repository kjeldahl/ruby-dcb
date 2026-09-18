require_relative "../test_helper"
require_relative "../support/postgres_database"
require_relative "../support/decision_model_contract"

# Runs the shared DecisionModel contract against PostgresStore; TestInMemoryStore
# runs the identical contract against InMemoryStore.
class TestDecisionModel < Minitest::Test
  cover "DcbEventStore::DecisionModel*"
  cover "DcbEventStore::Projection*"

  include PostgresDatabaseHelper
  include DecisionModelContract

  def setup
    setup_db
  end

  def teardown
    teardown_db
  end
end
