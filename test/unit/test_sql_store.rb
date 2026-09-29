require_relative "../test_helper"
require "json"
require "time"

# Unit tests for the backend-neutral parts of SqlStore: the abstract hooks a
# backend must implement, and the append/read orchestration built on top of
# them. FakeSqlStore implements the hooks over a plain array of row hashes,
# so the template logic is exercised without any database. It ignores the
# Query when fetching (dialect-level filtering is covered by the SqlBuilder
# and integration tests) and reports a configurable match count.
class TestSqlStore < Minitest::Test
  cover "DcbEventStore::SqlStore*"

  # Dialect for the fake rows: the RowMapper needs the tag list and timestamp
  # decoders. The real backends encode both in their own dialect (a PG array
  # literal and a driver-built Time for PostgreSQL), which SqlStore knows
  # nothing about, so the fake uses JSON and ISO 8601 text.
  module JsonDialect
    def self.encode_list(tags)
      JSON.generate(tags)
    end

    def self.decode_list(text)
      JSON.parse(text)
    end

    def self.decode_timestamp(value)
      DcbEventStore::SqlStore::Timestamp.parse(value)
    end
  end

  class FakeSqlStore < DcbEventStore::SqlStore
    attr_reader :rows, :notified, :lock_conditions, :import_locks, :fetched_limits
    attr_accessor :matching_count

    def initialize(**)
      super
      @row_mapper = DcbEventStore::SqlStore::RowMapper.new(JsonDialect, @upcaster)
      @rows = []
      @notified = []
      @lock_conditions = []
      @matching_count = 0
      @import_locks = 0
      @fetched_limits = []
    end

    private

    def with_write_transaction
      yield
    end

    def acquire_locks!(events, condition)
      @lock_conditions << [events, condition]
    end

    def count_matching(_query, _after)
      @matching_count
    end

    def lock_for_import!
      @import_locks += 1
    end

    def import_event(event)
      row = insert_event(event)
      row&.merge("schema_version" => (event.schema_version || 1).to_s)
    end

    def insert_event(event)
      return nil if @rows.any? { |row| row["event_id"] == event.id }

      row = {
        "sequence_position" => (@rows.size + 1).to_s,
        "type" => event.type,
        "data" => JSON.generate(event.data),
        "tags" => JsonDialect.encode_list(event.tags),
        "created_at" => Time.now.utc.iso8601(6),
        "event_id" => event.id,
        "causation_id" => event.causation_id,
        "correlation_id" => event.correlation_id,
        "schema_version" => "1"
      }
      @rows << row
      row
    end

    def fetch_batch(_query, after:, before:, order:, limit:)
      @fetched_limits << limit
      return @rows.drop(after.to_i).first(limit) if order == :asc

      @rows.take(before ? before - 1 : @rows.size).reverse.first(limit)
    end

    def notify_appended(position)
      @notified << position
    end
  end

  def setup
    @store = FakeSqlStore.new
  end

  def event(type: "A", **attrs)
    DcbEventStore::Event.new(type: type, **attrs)
  end

  # --- abstract hooks ---

  def refute_implemented(name, *args, **kwargs)
    store = DcbEventStore::SqlStore.new
    error = assert_raises(NotImplementedError) { store.send(name, *args, **kwargs) }
    assert_equal "DcbEventStore::SqlStore must implement ##{name}", error.message
  end

  def test_hooks_raise_not_implemented
    refute_implemented(:with_write_transaction)
    refute_implemented(:acquire_locks!, [], nil)
    refute_implemented(:count_matching, DcbEventStore::Query.all, nil)
    refute_implemented(:insert_event, event)
    refute_implemented(:lock_for_import!)
    refute_implemented(:import_event, event)
    refute_implemented(:fetch_batch, DcbEventStore::Query.all, after: nil, before: nil, order: :asc, limit: 10)
    refute_implemented(:notify_appended, 1)
    refute_implemented(:listen)
    refute_implemented(:unlisten)
    refute_implemented(:wait_for_append)
  end

  def test_rejects_unknown_subscribe_instrumentation_mode
    assert_raises(ArgumentError) { FakeSqlStore.new(subscribe_instrumentation: :nope) }
  end

  # --- append orchestration ---

  def test_append_inserts_and_maps_events
    appended = @store.append([event(type: "A", data: {x: 1}, tags: ["t:1"]), event(type: "B")])

    assert_equal %w[A B], appended.map(&:type)
    assert_equal [1, 2], appended.map(&:sequence_position)
    assert_equal({x: 1}, appended[0].data)
    assert_equal ["t:1"], appended[0].tags
    assert_kind_of Time, appended[0].created_at
  end

  def test_append_wraps_single_event_and_notifies_last_position
    @store.append(event(type: "A"))
    @store.append([event(type: "B"), event(type: "C")])

    assert_equal [1, 3], @store.notified
  end

  def test_append_of_nothing_raises_before_writing
    assert_raises(ArgumentError) { @store.append([]) }
    assert_empty @store.notified
  end

  def test_append_skips_duplicate_ids_without_notifying_again
    duplicate = event(type: "A")
    @store.append([duplicate])

    assert_empty @store.append([duplicate])
    assert_equal [1], @store.notified
  end

  def test_append_without_condition_still_locks
    e = event
    @store.append([e])

    assert_equal [[[e], nil]], @store.lock_conditions
  end

  def test_append_with_satisfied_condition_locks_and_inserts
    condition = DcbEventStore::AppendCondition.new(fail_if_events_match: DcbEventStore::Query.all)

    e = event(type: "A")
    appended = @store.append([e], condition)

    assert_equal 1, appended.size
    assert_equal [[[e], condition]], @store.lock_conditions
  end

  def test_append_with_conflicting_condition_raises_and_writes_nothing
    @store.matching_count = 1
    condition = DcbEventStore::AppendCondition.new(fail_if_events_match: DcbEventStore::Query.all)

    error = assert_raises(DcbEventStore::ConditionNotMet) do
      @store.append([event(type: "A")], condition)
    end
    assert_equal "conflicting event(s)", error.message
    assert_empty @store.rows
    assert_empty @store.notified
  end

  # --- import orchestration ---

  def exported(type: "A", schema_version: 2)
    DcbEventStore::SequencedEvent.new(
      sequence_position: 50, type: type, data: {}, tags: [], created_at: Time.utc(2020, 1, 1),
      id: SecureRandom.uuid, causation_id: nil, correlation_id: nil, schema_version: schema_version
    )
  end

  def test_import_locks_once_inserts_in_order_and_notifies_last_position
    imported = @store.import([exported(type: "A"), exported(type: "B", schema_version: nil)])

    assert_equal 1, @store.import_locks
    assert_equal %w[A B], imported.map(&:type)
    assert_equal [1, 2], imported.map(&:sequence_position)
    assert_equal [2, 1], imported.map(&:schema_version)
    assert_equal [2], @store.notified
  end

  def test_import_wraps_a_single_event
    assert_equal 1, @store.import(exported).size
  end

  def test_import_of_nothing_takes_no_lock_and_skips_the_notification
    assert_empty @store.import([])
    assert_equal 0, @store.import_locks
    assert_empty @store.notified
  end

  def test_import_skips_stored_ids_without_notifying
    event = exported
    @store.import([event])

    assert_empty @store.import([event])
    assert_equal [1], @store.notified
  end

  # --- read orchestration ---

  def test_read_returns_a_lazy_enumerator_of_all_events
    @store.append([event(type: "A"), event(type: "B")])

    events = @store.read(DcbEventStore::Query.all)
    assert_kind_of Enumerator, events
    assert_equal %w[A B], events.map(&:type)
    assert_equal "A", @store.read(DcbEventStore::Query.all).first.type
  end

  def test_read_of_empty_store_yields_nothing
    assert_empty @store.read(DcbEventStore::Query.all).to_a
  end

  def test_read_from_resumes_after_a_position
    @store.append([event(type: "A"), event(type: "B"), event(type: "C")])

    events = @store.read_from(DcbEventStore::Query.all, after: 1).to_a
    assert_equal %w[B C], events.map(&:type)
  end

  def test_read_applies_the_upcaster
    upcaster = DcbEventStore::Upcaster.new
    upcaster.register("A", from_version: 1) { |data| data.merge(upgraded: true) }
    store = FakeSqlStore.new(upcaster: upcaster)
    store.append([event(type: "A", data: {x: 1})])

    read_back = store.read(DcbEventStore::Query.all).first
    assert_equal({x: 1, upgraded: true}, read_back.data)
    assert_equal 2, read_back.schema_version
  end

  def test_limit_goes_into_the_fetch
    @store.append([event(type: "A"), event(type: "B")])

    assert_equal %w[A], @store.read(DcbEventStore::Query.all, limit: 1).map(&:type)
    assert_equal [1], @store.fetched_limits
  end

  def test_backwards_read_passes_direction_and_bound_to_the_fetch
    @store.append([event(type: "A"), event(type: "B"), event(type: "C")])

    assert_equal %w[C B A], @store.read(DcbEventStore::Query.all, backwards: true).map(&:type)
    assert_equal %w[B A], @store.read_from(DcbEventStore::Query.all, before: 3, backwards: true).map(&:type)
  end

  # A limit that ends exactly on a page boundary is used up there: no
  # further fetch for rows the read would not yield.
  def test_limit_on_a_page_boundary_stops_without_another_fetch
    batch = DcbEventStore::SqlStore::BATCH_SIZE
    @store.append(Array.new(batch + 1) { event(type: "A") })

    assert_equal batch, @store.read(DcbEventStore::Query.all, limit: batch).count
    assert_equal [batch], @store.fetched_limits
  end

  def test_limit_past_a_page_asks_the_next_page_for_the_rest_only
    batch = DcbEventStore::SqlStore::BATCH_SIZE
    @store.append(Array.new(batch + 5) { event(type: "A") })

    read_back = @store.read(DcbEventStore::Query.all, limit: batch + 2).map(&:sequence_position)
    assert_equal (1..(batch + 2)).to_a, read_back
    assert_equal [batch, 2], @store.fetched_limits
  end

  def test_backwards_pages_continue_before_the_last_row
    batch = DcbEventStore::SqlStore::BATCH_SIZE
    @store.append(Array.new(batch + 1) { event(type: "A") })

    read_back = @store.read(DcbEventStore::Query.all, backwards: true).map(&:sequence_position)
    assert_equal (1..(batch + 1)).to_a.reverse, read_back
  end

  # Paging stops only when a batch comes back short, so a stream that is an
  # exact multiple of BATCH_SIZE must not lose its tail to an early break.
  def test_read_pages_until_a_short_batch
    events = Array.new(DcbEventStore::SqlStore::BATCH_SIZE + 1) { event(type: "A") }
    @store.append(events)

    read_back = @store.read(DcbEventStore::Query.all).to_a
    assert_equal events.size, read_back.size
    assert_equal (1..events.size).to_a, read_back.map(&:sequence_position)
  end
end
