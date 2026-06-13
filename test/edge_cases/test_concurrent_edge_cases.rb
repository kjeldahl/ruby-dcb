require "test_helper"
require "concurrent"

# Tests for concurrent edge cases
class TestConcurrentEdgeCases < Minitest::Test
  cover "DcbEventStore::Store*"

  def setup
    @conn = PG.connect(dbname: "dcb_event_store_test")
    DcbEventStore::Schema.create!(@conn)
    @store = DcbEventStore::Store.new(@conn)
  end

  def teardown
    @conn.exec("TRUNCATE TABLE events")
    @conn.close
  end

  # --- Concurrent appends with same tags ---

  def test_concurrent_appends_same_tags
    threads = []
    errors = []
    success_count = Concurrent::AtomicFixnum.new(0)

    10.times do |i|
      threads << Thread.new do
        begin
          event = DcbEventStore::Event.new(
            type: "Event",
            data: { thread: i, timestamp: Time.now.to_i },
            tags: ["shared:resource"]
          )
          result = @store.append([event])
          success_count.increment if result.size == 1
        rescue => e
          errors << e
        end
      end
    end

    threads.each(&:join)

    # All should succeed (no conflicts without conditions)
    assert_equal 0, errors.size
    assert_equal 10, success_count.value

    # Verify all events were stored
    all_events = @store.read(DcbEventStore::Query.all).to_a
    assert_equal 10, all_events.size
  end

  def test_concurrent_appends_with_conditions
    # First, create an initial event
    initial = DcbEventStore::Event.new(type: "Initial", tags: ["resource:1"])
    @store.append([initial])

    threads = []
    success_count = Concurrent::AtomicFixnum.new(0)
    conflict_count = Concurrent::AtomicFixnum.new(0)

    # Each thread tries to append with a condition that will fail for most
    10.times do |i|
      threads << Thread.new do
        query = DcbEventStore::Query.new([
          DcbEventStore::QueryItem.new(tags: ["resource:1"])
        ])
        condition = DcbEventStore::AppendCondition.new(
          fail_if_events_match: query,
          after: 0
        )

        event = DcbEventStore::Event.new(
          type: "Update",
          data: { thread: i },
          tags: ["resource:1"]
        )

        begin
          result = @store.append([event], condition)
          success_count.increment if result.size == 1
        rescue DcbEventStore::ConditionNotMet
          conflict_count.increment
        end
      end
    end

    threads.each(&:join)

    # Only one should succeed (the first to acquire the lock)
    # The rest should get ConditionNotMet
    assert_equal 1, success_count.value
    assert_equal 9, conflict_count.value

    # Verify only 2 events total (initial + 1 successful update)
    all_events = @store.read(DcbEventStore::Query.all).to_a
    assert_equal 2, all_events.size
  end

  # --- Concurrent reads and appends ---

  def test_concurrent_reads_and_appends
    # Pre-populate with some events
    5.times do |i|
      event = DcbEventStore::Event.new(type: "Initial", data: { id: i }, tags: ["initial"])
      @store.append([event])
    end

    threads = []
    read_counts = Concurrent::AtomicFixnum.new(0)
    append_counts = Concurrent::AtomicFixnum.new(0)

    # Mix of readers and writers
    10.times do |i|
      if i.even?
        # Reader thread
        threads << Thread.new do
          events = @store.read(DcbEventStore::Query.all).to_a
          read_counts.increment
          # Just verify we can read
          assert events.is_a?(Array)
        end
      else
        # Writer thread
        threads << Thread.new do
          event = DcbEventStore::Event.new(
            type: "Concurrent",
            data: { thread: i },
            tags: ["concurrent"]
          )
          result = @store.append([event])
          append_counts.increment if result.size == 1
        end
      end
    end

    threads.each(&:join)

    # All operations should complete successfully
    assert read_counts.value > 0
    assert append_counts.value > 0
    assert_equal 5 + append_counts.value, @store.read(DcbEventStore::Query.all).to_a.size
  end

  # --- Edge cases with duplicate detection ---

  def test_duplicate_event_id_silently_ignored
    id = SecureRandom.uuid
    event1 = DcbEventStore::Event.new(type: "Event1", data: { x: 1 }, id: id, tags: ["test"])
    event2 = DcbEventStore::Event.new(type: "Event2", data: { x: 2 }, id: id, tags: ["test"])

    result1 = @store.append([event1])
    assert_equal 1, result1.size

    result2 = @store.append([event2])
    assert_equal 0, result2.size # Duplicate ID silently ignored

    all_events = @store.read(DcbEventStore::Query.all).to_a
    assert_equal 1, all_events.size
    assert_equal "Event1", all_events[0].type
    assert_equal({ x: 1 }, all_events[0].data)
  end

  def test_duplicate_in_batch
    id = SecureRandom.uuid
    events = [
      DcbEventStore::Event.new(type: "First", data: { x: 1 }, id: id, tags: ["test"]),
      DcbEventStore::Event.new(type: "Second", data: { x: 2 }, tags: ["test"]),
      DcbEventStore::Event.new(type: "Third", data: { x: 3 }, id: id, tags: ["test"]) # Duplicate ID
    ]

    result = @store.append(events)
    assert_equal 2, result.size # Only First and Second appended

    all_events = @store.read(DcbEventStore::Query.all).to_a
    assert_equal 2, all_events.size
  end

  # --- Edge cases with conditions ---

  def test_condition_with_empty_query
    condition = DcbEventStore::AppendCondition.new(
      fail_if_events_match: DcbEventStore::Query.all,
      after: 0
    )

    event = DcbEventStore::Event.new(type: "Event", tags: ["test"])
    result = @store.append([event], condition)
    assert_equal 1, result.size
  end

  def test_condition_with_no_matching_events
    # Store is empty, condition should pass
    condition = DcbEventStore::AppendCondition.new(
      fail_if_events_match: DcbEventStore::Query.new([
        DcbEventStore::QueryItem.new(event_types: ["NonExistent"])
      ]),
      after: 0
    )

    event = DcbEventStore::Event.new(type: "Event", tags: ["test"])
    result = @store.append([event], condition)
    assert_equal 1, result.size
  end

  def test_condition_with_after_position
    # Create initial events
    initial = @store.append([
      DcbEventStore::Event.new(type: "A", tags: ["test"]),
      DcbEventStore::Event.new(type: "B", tags: ["test"])
    ])

    # Condition should pass for events after position 1
    condition = DcbEventStore::AppendCondition.new(
      fail_if_events_match: DcbEventStore::Query.new([
        DcbEventStore::QueryItem.new(event_types: ["A", "B"])
      ]),
      after: 1
    )

    event = DcbEventStore::Event.new(type: "C", tags: ["test"])
    result = @store.append([event], condition)
    assert_equal 1, result.size
  end

  # --- Edge cases with queries ---

  def test_query_with_empty_items
    query = DcbEventStore::Query.new([])
    events = @store.read(query).to_a
    assert_equal 0, events.size
  end

  def test_query_with_nil_tags
    event = DcbEventStore::Event.new(type: "Event", tags: [])
    @store.append([event])

    query = DcbEventStore::Query.new([
      DcbEventStore::QueryItem.new(event_types: ["Event"])
    ])
    events = @store.read(query).to_a
    assert_equal 1, events.size
  end

  def test_query_with_wildcard_type
    @store.append([DcbEventStore::Event.new(type: "OrderCreated", tags: ["order:1"])])
    @store.append([DcbEventStore::Event.new(type: "OrderUpdated", tags: ["order:1"])])

    # Query for all Order* types
    query = DcbEventStore::Query.new([
      DcbEventStore::QueryItem.new(event_types: ["OrderCreated", "OrderUpdated"])
    ])
    events = @store.read(query).to_a
    assert_equal 2, events.size
  end
end
