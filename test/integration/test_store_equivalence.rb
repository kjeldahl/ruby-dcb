require_relative "../test_helper"
require_relative "../support/postgres_database"
require_relative "../support/store_contract"
require_relative "../support/special_characters_contract"

# Runs the shared store contracts against PostgresStore.
# TestInMemoryStore runs the identical contracts against InMemoryStore,
# so a green run of both proves the two implementations are equivalent.
class TestStoreEquivalence < Minitest::Test
  cover "DcbEventStore::PostgresStore*"
  cover "DcbEventStore::SqlStore*"

  include PostgresDatabaseHelper
  include StoreContract
  include SpecialCharactersContract

  def setup
    setup_db
  end

  def teardown
    teardown_db
  end

  # Applies the same scripted operations to both stores and compares the
  # observable results field by field (created_at is wall-clock and
  # therefore excluded).
  def test_same_operations_produce_equivalent_results
    pg_store = @store
    memory_store = DcbEventStore::InMemoryStore.new

    script = lambda do |store|
      ids = Array.new(4) { SecureRandom.uuid }
      corr = SecureRandom.uuid

      appended = []
      appended += store.append([
                                 DcbEventStore::Event.new(type: "CourseDefined", data: {capacity: 10},
                                                          tags: ["course:c1"], id: ids[0]),
                                 DcbEventStore::Event.new(type: "StudentRegistered", data: {"name" => "Ada"},
                                                          tags: ["student:s1"], id: ids[1], correlation_id: corr)
                               ])

      guard = DcbEventStore::AppendCondition.new(
        fail_if_events_match: DcbEventStore::Query.new([
                                                         DcbEventStore::QueryItem.new(
                                                           event_types: ["StudentSubscribed"],
                                                           tags: ["student:s1", "course:c1"]
                                                         )
                                                       ])
      )
      appended += store.append(
        [DcbEventStore::Event.new(type: "StudentSubscribed", tags: ["student:s1", "course:c1"], id: ids[2])],
        guard
      )

      # Same condition again must now fail on both stores.
      failure = assert_raises(DcbEventStore::ConditionNotMet) do
        store.append(
          [DcbEventStore::Event.new(type: "StudentSubscribed", tags: ["student:s1", "course:c1"], id: ids[3])],
          guard
        )
      end

      filtered = store.read(
        DcbEventStore::Query.new([
                                   DcbEventStore::QueryItem.new(event_types: [], tags: ["student:s1"])
                                 ])
      ).to_a
      from_position = store.read_from(DcbEventStore::Query.all, after: appended[0].sequence_position).to_a

      {
        appended: appended.map { |e| comparable(e) },
        all: store.read(DcbEventStore::Query.all).to_a.map { |e| comparable(e) },
        filtered: filtered.map { |e| comparable(e) },
        from_position: from_position.map { |e| comparable(e) },
        failure_class: failure.class
      }
    end

    pg_result = script.call(pg_store)
    memory_result = script.call(memory_store)

    assert_equal pg_result, memory_result
  end

  private

  # Event ids are random per script run, so identity fields are reduced to
  # presence; everything else must match exactly.
  def comparable(event)
    {
      sequence_position: event.sequence_position,
      type: event.type,
      data: event.data,
      tags: event.tags,
      schema_version: event.schema_version,
      has_id: !event.id.nil?,
      causation_id: event.causation_id,
      correlation_id: event.correlation_id ? :present : nil
    }
  end
end
