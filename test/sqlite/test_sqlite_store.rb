require_relative "../test_helper"
require_relative "../support/sqlite_database"
require_relative "../support/store_contract"
require_relative "../support/special_characters_contract"
require_relative "../support/client_contract"
require_relative "../support/decision_model_contract"
require_relative "../support/upcaster_contract"
require_relative "../support/in_memory_equivalence_contract"
require_relative "../support/snapshot_decision_model_contract"

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
  include SnapshotDecisionModelContract

  def setup
    setup_db
  end

  def teardown
    teardown_db
  end

  # For SnapshotDecisionModelContract: the snapshot table lives in the same
  # throwaway database file as the events.
  def build_snapshot_store
    DcbEventStore::Snapshots::SqliteSnapshotStore::Schema.create!(@db)
    DcbEventStore::Snapshots::SqliteSnapshotStore.new(@db)
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

  # --- JSON encoding edge cases ---
  #
  # Tags and type lists travel as JSON arrays and are expanded with json_each,
  # so a tag made of JSON metacharacters must survive the round trip and still
  # match a containment query. (Quotes, commas, braces, backslashes, Unicode
  # and empty strings are covered for every backend by
  # SpecialCharactersContract; pagination across the read batch boundary by
  # StoreContract.)
  JSON_TAGS = ['["json"]', "[", "]", "{\"a\": 1}", '\\"', "北京🎉"].freeze

  def test_tags_made_of_json_metacharacters_round_trip
    @store.append([DcbEventStore::Event.new(type: "A", tags: JSON_TAGS)])

    assert_equal JSON_TAGS, @store.read(DcbEventStore::Query.all).first.tags
  end

  def test_containment_query_matches_a_tag_made_of_json_metacharacters
    @store.append([DcbEventStore::Event.new(type: "A", tags: JSON_TAGS)])
    @store.append([DcbEventStore::Event.new(type: "A", tags: ["plain"])])

    JSON_TAGS.each do |tag|
      events = @store.read(DcbEventStore::Query.new([
                                                      DcbEventStore::QueryItem.new(event_types: [], tags: [tag])
                                                    ])).to_a

      assert_equal 1, events.size, "expected only the JSON-tagged event to match #{tag.inspect}"
      assert_equal JSON_TAGS, events[0].tags
    end
  end

  # An event type that would need quoting in the JSON list the types filter is
  # bound as.
  def test_type_made_of_json_metacharacters_is_matched
    @store.append([DcbEventStore::Event.new(type: '["A"]')])
    @store.append([DcbEventStore::Event.new(type: "A")])

    events = @store.read(DcbEventStore::Query.new([
                                                    DcbEventStore::QueryItem.new(event_types: ['["A"]'])
                                                  ])).to_a

    assert_equal ['["A"]'], events.map(&:type)
  end

  # Two events with one id inside a single append: the first insert wins, the
  # second hits ON CONFLICT DO NOTHING and returns no row, so it must be left
  # out of the result and must not write tag rows either. The skipped row still
  # consumes an AUTOINCREMENT value, so positions have a gap -- the same
  # behavior BIGSERIAL gives on PostgreSQL.
  def test_duplicate_id_within_one_batch_is_stored_once
    id = SecureRandom.uuid
    appended = @store.append([
                               DcbEventStore::Event.new(type: "A", id: id, tags: ["t:1"]),
                               DcbEventStore::Event.new(type: "B", id: id, tags: ["t:2"]),
                               DcbEventStore::Event.new(type: "C", tags: ["t:3"])
                             ])

    assert_equal %w[A C], appended.map(&:type)
    assert_equal [1, 3], appended.map(&:sequence_position)
    assert_equal %w[A C], @store.read(DcbEventStore::Query.all).map(&:type)
    assert_equal [["t:1", 1], ["t:3", 3]], tag_rows
  end

  # The tag containment clause matches through the event_tags table, which an
  # untagged event has no row in; a query without tags must not be narrowed by
  # that table.
  def test_type_only_query_matches_an_untagged_event
    @store.append([DcbEventStore::Event.new(type: "A")])
    @store.append([DcbEventStore::Event.new(type: "B", tags: ["t:1"])])

    events = @store.read(DcbEventStore::Query.new([
                                                    DcbEventStore::QueryItem.new(event_types: ["A"])
                                                  ])).to_a

    assert_equal ["A"], events.map(&:type)
    assert_empty events[0].tags
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

  private

  def tag_rows
    @db.execute("SELECT tag, sequence_position FROM event_tags")
       .map { |row| [row["tag"], row["sequence_position"]] }.sort
  end
end
