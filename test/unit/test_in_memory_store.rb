require_relative "../test_helper"
require_relative "../support/store_contract"
require_relative "../support/special_characters_contract"
require_relative "../support/client_contract"
require_relative "../support/decision_model_contract"
require_relative "../support/upcaster_contract"
require_relative "../support/snapshot_decision_model_contract"
require_relative "../support/import_export_contract"

# Runs the shared backend contracts against InMemoryStore, proving it behaves
# like PostgresStore (which runs the same contracts in
# test/integration/) — no database required.
class TestInMemoryStore < Minitest::Test
  cover "DcbEventStore::InMemoryStore*"

  include StoreContract
  include SpecialCharactersContract
  include ClientContract
  include DecisionModelContract
  include UpcasterContract
  include SnapshotDecisionModelContract
  include ImportExportContract

  def setup
    @store = build_store
  end

  def build_store(upcaster: nil)
    DcbEventStore::InMemoryStore.new(upcaster: upcaster)
  end

  def build_snapshot_store
    DcbEventStore::Snapshots::InMemorySnapshotStore.new
  end

  def test_constructs_without_arguments
    store = DcbEventStore::InMemoryStore.new
    assert_empty store.read(DcbEventStore::Query.all).to_a
  end

  def test_query_item_with_no_types_and_no_tags_matches_nothing
    @store.append([DcbEventStore::Event.new(type: "A", tags: ["t:1"])])

    query = DcbEventStore::Query.new([
                                       DcbEventStore::QueryItem.new(event_types: [], tags: [])
                                     ])
    assert_empty @store.read(query).to_a
  end

  def test_sequence_positions_start_at_one_and_increase
    appended = @store.append([
                               DcbEventStore::Event.new(type: "A"),
                               DcbEventStore::Event.new(type: "B")
                             ])
    assert_equal [1, 2], appended.map(&:sequence_position)
  end

  def test_subscribe_catches_up_then_receives_live_events
    @store.append([DcbEventStore::Event.new(type: "Old1")])
    @store.append([DcbEventStore::Event.new(type: "Old2")])

    received = []
    @store.subscribe(DcbEventStore::Query.all) { |event| received << event }

    assert_equal %w[Old1 Old2], received.map(&:type)

    @store.append([DcbEventStore::Event.new(type: "New1")])
    assert_equal %w[Old1 Old2 New1], received.map(&:type)
  end

  def test_subscribe_after_skips_earlier_events
    appended = @store.append([
                               DcbEventStore::Event.new(type: "Old"),
                               DcbEventStore::Event.new(type: "Recent")
                             ])

    received = []
    @store.subscribe(DcbEventStore::Query.all, after: appended[0].sequence_position) do |event|
      received << event
    end

    assert_equal %w[Recent], received.map(&:type)
  end

  def test_subscribe_filtered_query
    received = []
    query = DcbEventStore::Query.new([
                                       DcbEventStore::QueryItem.new(event_types: ["Wanted"])
                                     ])
    @store.subscribe(query, after: 0) { |event| received << event }

    @store.append([DcbEventStore::Event.new(type: "Ignored")])
    @store.append([DcbEventStore::Event.new(type: "Wanted")])

    assert_equal 1, received.size
    assert_equal "Wanted", received[0].type
  end

  def test_subscribe_returns_nil
    assert_nil @store.subscribe(DcbEventStore::Query.all) { |event| event }
  end

  def test_subscribe_each_event_delivered_once
    received = []
    @store.subscribe(DcbEventStore::Query.all) { |event| received << event }

    @store.append([DcbEventStore::Event.new(type: "A")])
    @store.append([DcbEventStore::Event.new(type: "B")])

    assert_equal %w[A B], received.map(&:type)
    assert_equal received.map(&:sequence_position).uniq, received.map(&:sequence_position)
  end
end
