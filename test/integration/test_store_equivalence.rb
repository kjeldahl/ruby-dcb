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
  # Rows written before Event dropped repeated tags keep them: a read must
  # still match and hand the tags back as stored.
  def test_reads_legacy_row_with_duplicate_tags
    @conn.exec_params("INSERT INTO events (event_id, type, data, tags, schema_version) " \
                      "VALUES ($1, 'A', '{}', '{dup,dup}', 1)", [SecureRandom.uuid])

    query = DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: ["A"], tags: ["dup"])])
    events = @store.read(query).to_a

    assert_equal 1, events.size
    assert_equal %w[dup dup], events[0].tags
  end
end
