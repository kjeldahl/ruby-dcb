require_relative "../test_helper"
require_relative "../support/postgres_database"
require_relative "../support/decision_model_contract"
require_relative "../support/snapshot_decision_model_contract"

# Runs the shared DecisionModel contract against PostgresStore; TestInMemoryStore
# runs the identical contract against InMemoryStore.
class TestDecisionModel < Minitest::Test
  cover "DcbEventStore::DecisionModel*"
  cover "DcbEventStore::Projection*"

  include PostgresDatabaseHelper
  include DecisionModelContract
  include SnapshotDecisionModelContract

  def setup
    setup_db
  end

  def teardown
    teardown_db
  end

  # For SnapshotDecisionModelContract: the snapshot table lives next to the
  # events in the test database, emptied for each test.
  def build_snapshot_store
    DcbEventStore::Snapshots::PostgresSnapshotStore::Schema.create!(@conn)
    DcbEventStore::Snapshots::PostgresSnapshotStore.new(@conn).tap(&:clear)
  end
end
