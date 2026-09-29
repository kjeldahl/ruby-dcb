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

  # namespace: is accepted for parity with the SQL stores and validated the
  # same way, but every instance is its own log regardless.
  def test_namespace_is_kept_and_validated
    assert_predicate DcbEventStore::InMemoryStore.new.namespace, :default?
    assert_equal "billing", DcbEventStore::InMemoryStore.new(namespace: "billing").namespace.name
    assert_raises(ArgumentError) { DcbEventStore::InMemoryStore.new(namespace: "Bad Name") }
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

  # -- Type and tag indexes ---------------------------------------------------

  # t1 = [1, 4], t2 = [1, 2, 3]: the read starts from t1's list and must
  # still drop position 4, which lacks t2.
  def test_an_item_with_two_tags_filters_its_shortest_list_by_the_other
    append_events(%w[A t1 t2], %w[A t2], %w[A t2], %w[A t1])

    assert_equal [1], positions(@store.read(query(tags: %w[t1 t2])))
  end

  # The type list [2] is the shortest: position 2 still has to carry the tag.
  def test_an_item_read_from_its_type_list_filters_by_its_tags
    append_events(%w[A t], %w[B], %w[A t])

    assert_empty positions(@store.read(query(types: %w[B], tags: %w[t])))
  end

  def test_an_event_matching_two_items_is_read_once
    append_events(%w[A t], %w[B t])

    both = DcbEventStore::Query.new([item(types: %w[A]), item(tags: %w[t])])
    assert_equal [1, 2], positions(@store.read(both))
  end

  def test_read_from_after_every_matching_position_is_empty
    append_events(%w[A t], %w[B], %w[B])

    assert_empty positions(@store.read_from(query(tags: %w[t]), after: 2))
  end

  # The bound falls on a position the tag's list does not hold.
  def test_read_from_before_a_position_the_query_does_not_match
    append_events(%w[A t], %w[B], %w[A t], %w[B], %w[A t])

    assert_equal [3, 1], positions(@store.read_from(query(tags: %w[t]), before: 4, backwards: true))
  end

  # A read costs what it matches: one row visited to check the item, one to
  # build the event, whichever list (type or tag) is the short one.
  def test_a_read_visits_only_the_rows_of_the_shortest_list
    50.times { append_events(%w[Common shared]) }
    append_events(%w[Rare shared], %w[Common shared rare])

    rare_type = visited_rows { @store.read(query(types: %w[Rare], tags: %w[shared])).to_a }
    rare_tag = visited_rows { @store.read(query(types: %w[Common], tags: %w[shared rare])).to_a }

    assert_equal [51, 51], rare_type
    assert_equal [52, 52], rare_tag
  end

  # A subscriber appending from its block sees its own event in the same
  # forward read.
  def test_a_forward_read_sees_events_appended_while_it_runs
    append_events(%w[A t])
    seen = @store.read(query(tags: %w[t])).map do |event|
      append_events(%w[B t]) if event.sequence_position == 1
      event.sequence_position
    end

    assert_equal [1, 2], seen
  end

  private

  def append_events(*specs)
    specs.each do |type, *tags|
      @store.append(DcbEventStore::Event.new(type: type, tags: tags))
    end
  end

  def item(types: [], tags: [])
    DcbEventStore::QueryItem.new(event_types: types, tags: tags)
  end

  def query(types: [], tags: [])
    DcbEventStore::Query.new([item(types: types, tags: tags)])
  end

  def positions(events)
    events.map(&:sequence_position)
  end

  def visited_rows
    visited = []
    @store.define_singleton_method(:row_at) do |position|
      visited << position
      super(position)
    end
    yield
    visited
  end
end
