require_relative "../test_helper"
require_relative "../support/postgres_database"
require_relative "../support/in_flight_append"

# A position is taken at INSERT and becomes visible at COMMIT, so appends on
# disjoint tags, which share no lock, can commit out of position order. What
# reads the log while one of them is in flight must not step past it: a
# subscriber (issue #54) and a snapshot (issue #55).
class TestOutOfOrderCommit < Minitest::Test
  include PostgresDatabaseHelper
  include InFlightAppendHelper

  cover "DcbEventStore::PostgresStore#subscription_cursor"
  cover "DcbEventStore::PostgresStore#deliver_new"
  cover "DcbEventStore::PostgresStore#fetch_in_commit_order"
  cover "DcbEventStore::PostgresStore#wait_for_append"
  cover "DcbEventStore::PostgresStore#settled?"
  cover "DcbEventStore::PostgresStore#settled"
  cover "DcbEventStore::PostgresStore#settle"
  cover "DcbEventStore::PostgresStore#settle_locks!"
  cover "DcbEventStore::PostgresStore#settle_lock_timeout"
  cover "DcbEventStore::PostgresStore#pending?"

  def setup
    setup_db
    @threads = []
    @connections = []
  end

  def teardown
    @threads.each(&:kill).each { |t| t.join(1) }
    @connections.each(&:close)
    teardown_db
  end

  def event(type, *tags) = DcbEventStore::Event.new(type: type, tags: tags)

  def query(*items) = DcbEventStore::Query.new(items)

  def item(event_types: [], tags: []) = DcbEventStore::QueryItem.new(event_types: event_types, tags: tags)

  def connection
    PostgresDatabaseHelper.connection.tap { |conn| @connections << conn }
  end

  # Subscribes on its own connection; what it delivers lands in the queue
  # returned, as [type, position].
  def subscribe(query = DcbEventStore::Query.all, after: nil)
    received = Queue.new
    store = DcbEventStore::PostgresStore.new(connection)
    @threads << Thread.new do
      store.subscribe(query, after: after) { |e| received << [e.type, e.sequence_position] }
    end
    received
  end

  def take(queue, count, timeout: 3)
    Array.new(count) { queue.pop(timeout: timeout) }
  end

  # Gives a subscriber the time to deliver what it would, then checks it
  # delivered nothing.
  def assert_nothing_delivered(queue)
    sleep 0.3
    assert_empty queue, "subscriber delivered an event past an append still in flight"
  end

  # --- subscribe (issue #54) ---------------------------------------------

  # The repro of the issue: Fast (position 2) commits while Slow (position
  # 1) is in flight. Delivering Fast would move the cursor past Slow for
  # good; it is held back until Slow commits, then both arrive.
  def test_subscriber_delivers_an_event_committed_below_one_already_visible
    received = subscribe
    with_in_flight_append([event("Slow", "a")]) do |release|
      @store.append([event("Fast", "b")])
      assert_nothing_delivered(received)

      release.call
      @store.append([event("Later", "c")])
      assert_equal [["Slow", 1], ["Fast", 2], ["Later", 3]], take(received, 3)
    end
  end

  # The same during catch-up: a subscription started while Slow is in
  # flight does not deliver what lies past it either.
  def test_catch_up_holds_back_behind_an_append_in_flight
    with_in_flight_append([event("Slow", "a")]) do |release|
      @store.append([event("Fast", "b")])
      received = subscribe
      assert_nothing_delivered(received)

      release.call
      assert_equal [["Slow", 1], ["Fast", 2]], take(received, 2)
    end
  end

  # What holds a subscriber back need not be an append, and then no NOTIFY
  # says it finished: the subscriber polls while it is held back.
  def test_subscriber_held_back_by_another_transaction_resumes_on_its_own
    received = subscribe
    other = connection
    other.exec("BEGIN")
    other.exec("SELECT pg_current_xact_id()")
    @store.append([event("A", "a")])
    assert_nothing_delivered(received)

    other.exec("COMMIT")
    assert_equal [["A", 1]], take(received, 1)
  end

  # A transaction that took its id before another append took its own, and
  # inserts after it, commits with a higher position and a lower tx_id: the
  # subscription delivers in tx_id order, and +after:+ resumes in it.
  def test_after_resumes_in_commit_order
    early = connection
    early.exec("BEGIN")
    early.exec("SELECT pg_current_xact_id()")
    @store.append([event("Second", "b")]) # position 1, later tx
    early.exec("INSERT INTO events (type) VALUES ('First')") # position 2, earlier tx
    early.exec("COMMIT")

    assert_equal [["First", 2], ["Second", 1]], take(subscribe, 2)
    assert_equal [["Second", 1]], take(subscribe(after: 2), 1)

    after_second = subscribe(after: 1)
    @store.append([event("Third", "c")])
    assert_equal [["Third", 3]], take(after_second, 1)
  end

  # A filtered subscription is held back the same way: what it matches past
  # the in-flight append waits for its commit.
  def test_filtered_subscriber_sees_matches_committed_out_of_order
    received = subscribe(query(item(event_types: ["Wanted"])))
    with_in_flight_append([event("Wanted", "a")]) do |release|
      @store.append([event("Wanted", "b")])
      @store.append([event("Ignored", "c")])
      assert_nothing_delivered(received)

      release.call
      assert_equal [["Wanted", 1], ["Wanted", 2]], take(received, 2)
    end
  end

  # --- snapshots (issue #55) ---------------------------------------------

  def counter(name, query)
    DcbEventStore::Projection.new(
      initial_state: 0, handlers: { "Tick" => ->(state, _event) { state + 1 } }, query: query,
      snapshot: DcbEventStore::Snapshot.new(name: name, version: 1, every: 1)
    )
  end

  def build(snapshots, projection)
    DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, ticks: projection).states.fetch(:ticks)
  end

  # Tick at position 1 is in flight while Tick at 2 is committed: a
  # type-only query shares no tag lock, so the build reads 2 without 1.
  # Snapshotting that read at 2 would lose 1 for good; it is not written,
  # and the build after the commit writes a correct one.
  def assert_snapshot_waits_for_the_in_flight_append(projection, first, second)
    snapshots = DcbEventStore::Snapshots::PostgresSnapshotStore.new(@conn)
    snapshots.clear
    key = projection.snapshot.key(projection.query)

    with_in_flight_append([first]) do |release|
      @store.append([second])
      assert_equal 1, build(snapshots, projection)
      assert_nil snapshots.fetch(key), "snapshot written past an append in flight"

      release.call
    end

    assert_equal 2, build(snapshots, projection)
    assert_equal 2, snapshots.fetch(key).position
    assert_equal 2, build(snapshots, projection)
  end

  def test_type_only_snapshot_is_not_written_past_an_append_in_flight
    assert_snapshot_waits_for_the_in_flight_append(
      counter("ticks", query(item(event_types: ["Tick"]))), event("Tick", "a"), event("Tick", "b")
    )
  end

  def test_multi_tag_snapshot_is_not_written_past_an_append_in_flight
    assert_snapshot_waits_for_the_in_flight_append(
      counter("ticks", query(item(event_types: ["Tick"], tags: ["a"]), item(event_types: ["Tick"], tags: ["b"]))),
      event("Tick", "a"), event("Tick", "b")
    )
  end

  # settled? fails while an append that could write a match stays in flight,
  # and only then: a query on a tag the append does not touch settles.
  def test_settled_fails_only_for_queries_an_in_flight_append_can_match
    @store.append([event("Tick", "b")])
    with_in_flight_append([event("Tick", "a")]) do |release|
      refute @store.settled?(query(item(event_types: ["Tick"])), after: nil, through: 1, count: 1)
      refute @store.settled?(query(item(tags: ["a"])), after: nil, through: 1, count: 0)
      refute @store.settled?(DcbEventStore::Query.all, after: nil, through: 1, count: 1)
      assert @store.settled?(query(item(tags: ["b"])), after: nil, through: 1, count: 1)

      release.call
    end

    assert @store.settled?(query(item(tags: ["a"])), after: nil, through: 2, count: 1)
  end

  # A store whose settle checks wait long enough for a test to see them
  # waiting.
  class PatientStore < DcbEventStore::PostgresStore
    private

    def settle_lock_timeout = "5s"
  end

  # The check waits for the locks: an append in flight that commits within
  # the lock timeout is counted, not failed on. Released only once the check
  # is seen waiting on its lock.
  def test_settled_waits_for_an_append_in_flight
    @store.append([event("Tick", "b")])
    with_in_flight_append([event("Tick", "a")]) do |release|
      tick = query(item(event_types: ["Tick"]))
      settling = Thread.new { PatientStore.new(connection).settled?(tick, after: nil, through: 2, count: 2) }
      wait_for_a_lock_wait
      release.call
      assert settling.value
    end
  end

  def wait_for_a_lock_wait
    deadline = Time.now + 3
    until @conn.exec("SELECT 1 FROM pg_locks WHERE locktype = 'advisory' AND NOT granted").ntuples.positive?
      flunk "settle check never waited on a lock" if Time.now > deadline
      sleep 0.01
    end
  end

  # One transaction for a batch: a check whose lock times out does not fail
  # the ones after it.
  def test_settled_answers_each_check_of_a_batch
    @store.append([event("Tick", "b")])
    check = ->(q, count) { DcbEventStore::SettleCheck.new(query: q, after: nil, through: 1, count: count) }
    with_in_flight_append([event("Tick", "a")]) do |release|
      answers = @store.settled([check.call(query(item(tags: ["a"])), 0), check.call(query(item(tags: ["b"])), 1),
                                check.call(query(item(tags: ["b"])), 2)])
      assert_equal [false, true, false], answers
      release.call
    end
  end

  # NOTIFYs queued while the subscriber was busy (a long catch-up) are
  # drained by one wake-up, not answered with an empty read each.
  def test_waiting_drains_queued_notifications
    conn = connection
    store = DcbEventStore::PostgresStore.new(conn)
    store.send(:listen)
    3.times { @store.append([event("A", "a")]) }
    # A round trip on the listening connection: its backend sends every
    # notification committed so far ahead of the result.
    conn.exec("SELECT 1")

    store.send(:wait_for_append)

    assert_nil conn.wait_for_notify(0)
  end

  # The locks are released with the check: a later append on the tag does
  # not wait on them.
  def test_settled_releases_its_locks
    @store.settled?(query(item(tags: ["a"])), after: nil, through: 0, count: 0)
    @store.settled?(query(item(event_types: ["Tick"])), after: nil, through: 0, count: 0)

    other = DcbEventStore::PostgresStore.new(connection)
    on_ticks = DcbEventStore::AppendCondition.new(fail_if_events_match: query(item(event_types: ["Tick"])))
    appended = Thread.new { other.append([event("Tick", "a")], on_ticks) }
    assert appended.join(2), "append waited on a settle check's lock"
  end

  # Namespaces keep their own lock keys: an append in flight in another
  # namespace does not keep this one's snapshot from settling.
  def test_settled_ignores_an_append_in_flight_in_another_namespace
    DcbEventStore::PostgresStore::Schema.create!(@conn, namespace: "billing")
    with_in_flight_append([event("Tick", "a")], namespace: "billing") do |release|
      assert @store.settled?(query(item(event_types: ["Tick"])), after: nil, through: 0, count: 0)
      release.call
    end
  ensure
    DcbEventStore::PostgresStore::Schema.drop!(@conn, namespace: "billing")
  end
end
