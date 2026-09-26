require_relative "../test_helper"
require_relative "../support/postgres_database"
require_relative "../support/store_contract"
require_relative "../support/special_characters_contract"
require_relative "../support/in_memory_equivalence_contract"
require_relative "../support/import_export_contract"

# Runs the shared store contracts against PostgresStore.
# TestInMemoryStore runs the identical contracts against InMemoryStore,
# so a green run of both proves the two implementations are equivalent.
class TestStoreEquivalence < Minitest::Test
  cover "DcbEventStore::PostgresStore*"
  cover "DcbEventStore::SqlStore*"

  include PostgresDatabaseHelper
  include StoreContract
  include SpecialCharactersContract
  include InMemoryEquivalenceContract
  include ImportExportContract

  def setup
    setup_db
  end

  def teardown
    teardown_db
  end
end
