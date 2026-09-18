require_relative "../test_helper"
require_relative "../support/sqlite_database"
require_relative "../support/store_contract"
require_relative "../support/special_characters_contract"
require_relative "../support/client_contract"
require_relative "../support/decision_model_contract"
require_relative "../support/upcaster_contract"
require_relative "../support/in_memory_equivalence_contract"

# Runs the shared backend contracts against SqliteStore, the same ones
# PostgresStore (test/integration/) and InMemoryStore (test/unit/) run, plus
# the SQLite specifics of the append transaction.
class TestSqliteStore < Minitest::Test
  cover "DcbEventStore::SqliteStore*"
  cover "DcbEventStore::SqlStore*"

  include SqliteDatabaseHelper
  include StoreContract
  include SpecialCharactersContract
  include ClientContract
  include DecisionModelContract
  include UpcasterContract
  include InMemoryEquivalenceContract

  def setup
    setup_db
  end

  def teardown
    teardown_db
  end

  def test_constructs_with_only_a_connection
    store = DcbEventStore::SqliteStore.new(@db)

    assert_equal 1, store.append([DcbEventStore::Event.new(type: "A")]).size
    assert_equal 1, store.read(DcbEventStore::Query.all).to_a.size
  end

  # AUTOINCREMENT, so positions start at one and only ever grow.
  def test_sequence_positions_start_at_one_and_increase
    appended = @store.append([
                               DcbEventStore::Event.new(type: "A"),
                               DcbEventStore::Event.new(type: "B")
                             ])
    assert_equal [1, 2], appended.map(&:sequence_position)
  end

  # Rows are read by column name, so the store must not depend on the
  # connection it is handed being in hash mode already.
  def test_reads_a_connection_left_in_array_result_mode
    db = SqliteDatabaseHelper.connection(@db_path)
    db.results_as_hash = false
    store = DcbEventStore::SqliteStore.new(db, upcaster: nil)

    store.append([DcbEventStore::Event.new(type: "A", data: {n: 1}, tags: ["t:1"])])

    event = store.read(DcbEventStore::Query.all).first
    assert_equal "A", event.type
    assert_equal({n: 1}, event.data)
    assert_equal ["t:1"], event.tags
  ensure
    db&.close
  end

  # The tag index rows are written inside the append transaction, so a failed
  # condition must leave neither events nor tag rows behind.
  def test_rolled_back_append_leaves_no_tag_rows
    @store.append([DcbEventStore::Event.new(type: "Existing", tags: ["t:1"])])

    query = DcbEventStore::Query.new([
                                       DcbEventStore::QueryItem.new(event_types: ["Existing"], tags: ["t:1"])
                                     ])
    condition = DcbEventStore::AppendCondition.new(fail_if_events_match: query)

    assert_raises(DcbEventStore::ConditionNotMet) do
      @store.append([DcbEventStore::Event.new(type: "Rejected", tags: ["t:2"])], condition)
    end

    rows = @db.execute("SELECT tag, sequence_position FROM event_tags")
              .map { |row| [row["tag"], row["sequence_position"]] }

    assert_equal [["t:1", 1]], rows
  end

  # An exception from inside the transaction must roll it back and leave the
  # connection usable for the next append.
  def test_failed_transaction_is_rolled_back_and_connection_stays_usable
    # event_id is NOT NULL, so this insert fails inside the transaction.
    assert_raises(SQLite3::ConstraintException) do
      @store.append([DcbEventStore::Event.new(type: "A", id: nil)])
    end

    assert_empty @store.read(DcbEventStore::Query.all).to_a
    assert_equal 1, @store.append([DcbEventStore::Event.new(type: "B")]).size
  end
end
