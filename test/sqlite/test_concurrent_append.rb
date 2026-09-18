require_relative "../test_helper"
require_relative "../support/sqlite_database"
require "concurrent"

# Concurrent appends against SQLite, the SQLite counterpart of
# test/concurrency/test_concurrent_append.rb.
#
# Where PostgresStore serializes on per-tag advisory locks, SqliteStore relies
# on BEGIN IMMEDIATE: it takes the database's single write lock up front, so a
# condition check and the inserts that follow it cannot interleave with a
# competing append, and a connection that finds the lock taken waits for it
# (busy_timeout, set by Schema.configure!) instead of failing.
#
# Every thread opens its own connection on the shared database file; a
# ":memory:" database could not be shared, and one connection is not safe to
# use from several threads.
class TestSqliteConcurrentAppend < Minitest::Test
  cover "DcbEventStore::SqliteStore*"

  include SqliteDatabaseHelper

  def setup
    setup_db
  end

  def teardown
    teardown_db
  end

  # Same condition, same tag, 20 connections at once: the write lock plus the
  # in-transaction check must let exactly one of them through.
  def test_exactly_one_wins
    results = run_concurrently(20) do |i, store|
      query = DcbEventStore::Query.new([
                                         DcbEventStore::QueryItem.new(event_types: ["SeatReserved"],
                                                                      tags: ["course:c1"])
                                       ])
      condition = DcbEventStore::AppendCondition.new(fail_if_events_match: query)

      store.append(
        [DcbEventStore::Event.new(type: "SeatReserved", data: {student: "s#{i}"}, tags: ["course:c1"])],
        condition
      )
    end

    assert_equal 1, results.count(:success), "Expected exactly 1 success, got #{results.count(:success)}"
    assert_equal 19, results.count(:conflict)
    assert_equal 1, @store.read(DcbEventStore::Query.all).to_a.size
  end

  # Disjoint tags, so no condition can be met: serialized writes, but all of
  # them succeed.
  def test_non_conflicting_all_succeed
    n = 10
    results = run_concurrently(n) do |i, store|
      query = DcbEventStore::Query.new([
                                         DcbEventStore::QueryItem.new(event_types: ["Reserved"],
                                                                      tags: ["course:c#{i}"])
                                       ])
      condition = DcbEventStore::AppendCondition.new(fail_if_events_match: query)

      store.append([DcbEventStore::Event.new(type: "Reserved", tags: ["course:c#{i}"])], condition)
    end

    assert_equal n, results.count(:success), "All non-conflicting appends should succeed"
    assert_equal 0, results.count(:conflict)
    assert_equal n, @store.read(DcbEventStore::Query.all).to_a.size
  end

  # Unconditional appends have nothing to conflict over, so two connections
  # writing at the same moment must both be stored, at their own positions and
  # with their tag rows intact.
  def test_unconditional_concurrent_appends_both_succeed_with_distinct_positions
    results = run_concurrently(2) do |i, store|
      store.append([DcbEventStore::Event.new(type: "Noted", data: {thread: i}, tags: ["thread:t#{i}"])])
    end

    assert_equal 2, results.count(:success)

    events = @store.read(DcbEventStore::Query.all).to_a
    positions = events.map(&:sequence_position)

    assert_equal 2, events.size
    assert_equal positions.uniq, positions, "Positions must be unique"
    assert_equal [%w[thread:t0], %w[thread:t1]], events.map(&:tags).sort
  end

  private

  # Runs the block on `n` threads, each with its own store on its own
  # connection, released together by a barrier. Returns one :success or
  # :conflict per thread.
  def run_concurrently(n)
    barrier = Concurrent::CyclicBarrier.new(n)
    results = Concurrent::Array.new

    threads = n.times.map do |i|
      Thread.new do
        db = SqliteDatabaseHelper.connection(@db_path)
        store = DcbEventStore::SqliteStore.new(db)

        barrier.wait

        begin
          yield i, store
          results << :success
        rescue DcbEventStore::ConditionNotMet
          results << :conflict
        end
      ensure
        db&.close
      end
    end

    threads.each { |thread| thread.join(30) }
    results
  end
end
