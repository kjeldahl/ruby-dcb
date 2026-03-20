require_relative "../test_helper"
require_relative "../support/database"
require "concurrent"

class TestConcurrentAppend < Minitest::Test
  include DatabaseHelper

  def setup
    setup_db
  end

  def teardown
    teardown_db
  end

  def test_exactly_one_wins
    n = 20
    barrier = Concurrent::CyclicBarrier.new(n)
    results = Concurrent::Array.new

    threads = n.times.map do |i|
      Thread.new do
        conn = DatabaseHelper.connection
        store = DcbEventStore::Store.new(conn)

        query = DcbEventStore::Query.new([
                                           DcbEventStore::QueryItem.new(event_types: ["SeatReserved"],
                                                                        tags: ["course:c1"])
                                         ])
        condition = DcbEventStore::AppendCondition.new(fail_if_events_match: query)

        barrier.wait

        begin
          store.append(
            [DcbEventStore::Event.new(type: "SeatReserved", data: {student: "s#{i}"}, tags: ["course:c1"])],
            condition
          )
          results << :success
        rescue DcbEventStore::ConditionNotMet
          results << :conflict
        ensure
          conn.close
        end
      end
    end

    threads.each { |t| t.join(10) }

    assert_equal 1, results.count(:success), "Expected exactly 1 success, got #{results.count(:success)}"
    assert_equal n - 1, results.count(:conflict)

    all_events = @store.read(DcbEventStore::Query.all).to_a
    assert_equal 1, all_events.size
  end

  def test_non_conflicting_all_succeed
    n = 10
    barrier = Concurrent::CyclicBarrier.new(n)
    results = Concurrent::Array.new

    threads = n.times.map do |i|
      Thread.new do
        conn = DatabaseHelper.connection
        store = DcbEventStore::Store.new(conn)

        query = DcbEventStore::Query.new([
                                           DcbEventStore::QueryItem.new(event_types: ["Reserved"],
                                                                        tags: ["course:c#{i}"])
                                         ])
        condition = DcbEventStore::AppendCondition.new(fail_if_events_match: query)

        barrier.wait

        begin
          store.append(
            [DcbEventStore::Event.new(type: "Reserved", tags: ["course:c#{i}"])],
            condition
          )
          results << :success
        rescue DcbEventStore::ConditionNotMet
          results << :conflict
        ensure
          conn.close
        end
      end
    end

    threads.each { |t| t.join(10) }

    assert_equal n, results.count(:success), "All non-conflicting appends should succeed"
    assert_equal 0, results.count(:conflict)

    all_events = @store.read(DcbEventStore::Query.all).to_a
    assert_equal n, all_events.size
  end

  def test_retry_after_conflict
    barrier = Concurrent::CyclicBarrier.new(2)
    results = Concurrent::Array.new

    threads = 2.times.map do |i|
      Thread.new do
        conn = DatabaseHelper.connection
        store = DcbEventStore::Store.new(conn)

        barrier.wait

        3.times do
          events = store.read(DcbEventStore::Query.all).to_a
          max_pos = events.map(&:sequence_position).max

          query = DcbEventStore::Query.new([
                                             DcbEventStore::QueryItem.new(event_types: ["Evt"], tags: ["x:1"])
                                           ])
          condition = DcbEventStore::AppendCondition.new(fail_if_events_match: query, after: max_pos)

          begin
            store.append(
              [DcbEventStore::Event.new(type: "Evt", data: {thread: i}, tags: ["x:1"])],
              condition
            )
            results << :success
            break
          rescue DcbEventStore::ConditionNotMet
            results << :retry
          end
        end
      ensure
        conn.close
      end
    end

    threads.each { |t| t.join(10) }

    assert_equal 2, results.count(:success), "Both threads should eventually succeed"

    all_events = @store.read(DcbEventStore::Query.all).to_a
    assert_equal 2, all_events.size
  end

  def test_event_count_integrity
    n = 50
    barrier = Concurrent::CyclicBarrier.new(n)
    success_count = Concurrent::AtomicFixnum.new(0)

    threads = n.times.map do |_i|
      Thread.new do
        conn = DatabaseHelper.connection
        store = DcbEventStore::Store.new(conn)

        query = DcbEventStore::Query.new([
                                           DcbEventStore::QueryItem.new(event_types: ["Race"], tags: ["shared:1"])
                                         ])
        condition = DcbEventStore::AppendCondition.new(fail_if_events_match: query)

        barrier.wait

        begin
          store.append(
            [DcbEventStore::Event.new(type: "Race", tags: ["shared:1"])],
            condition
          )
          success_count.increment
        rescue DcbEventStore::ConditionNotMet
          # expected
        ensure
          conn.close
        end
      end
    end

    threads.each { |t| t.join(10) }

    all_events = @store.read(DcbEventStore::Query.all).to_a
    assert_equal success_count.value, all_events.size
    assert_equal 1, success_count.value

    positions = all_events.map(&:sequence_position)
    assert_equal positions.uniq, positions, "Positions must be unique"
  end
end
