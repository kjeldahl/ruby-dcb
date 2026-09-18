require_relative "../test_helper"
require_relative "../support/sqlite_database"

# Subscriptions against SQLite: the same cases test/integration/test_subscribe.rb
# runs against PostgreSQL, but woken by polling instead of LISTEN/NOTIFY.
#
# Every subscriber opens its own connection on the same database file, which is
# what the polling check is built for: PRAGMA data_version only moves for
# another connection's commits. The poll interval is shortened to 20ms so a
# test waits ticks rather than tenths of a second.
class TestSqliteSubscribe < Minitest::Test
  cover "DcbEventStore::SqliteStore#wait_for_append"
  cover "DcbEventStore::SqliteStore#listen"
  cover "DcbEventStore::SqlStore#subscribe"
  # The delivery helpers' return value (last delivered position) drives the
  # live loop's resume position, which only subscribe tests can observe.
  cover "DcbEventStore::StoreInstrumentation*"

  include SqliteDatabaseHelper

  POLL_INTERVAL = 0.02

  def setup
    setup_db
    @extra_dbs = []
  end

  def teardown
    @extra_dbs.each(&:close)
    teardown_db
  end

  def test_subscribe_receives_appended_event
    received = []

    subscriber = subscribe_in_thread(DcbEventStore::Query.all, after: 0) do |event|
      received << event
      received.size >= 1
    end

    @store.append([DcbEventStore::Event.new(type: "LiveEvent")])

    subscriber.join(5)
    assert_equal 1, received.size
    assert_equal "LiveEvent", received[0].type
  end

  def test_subscribe_catches_up_then_live
    @store.append([DcbEventStore::Event.new(type: "Old1")])
    @store.append([DcbEventStore::Event.new(type: "Old2")])

    received = []

    subscriber = subscribe_in_thread(DcbEventStore::Query.all) do |event|
      received << event
      received.size >= 3
    end

    @store.append([DcbEventStore::Event.new(type: "New1")])

    subscriber.join(5)
    assert_equal 3, received.size
    assert_equal %w[Old1 Old2 New1], received.map(&:type)
  end

  # after: skips the stored history, so only the live append is delivered.
  def test_subscribe_after_position_skips_earlier_events
    appended = @store.append([
                               DcbEventStore::Event.new(type: "Old1"),
                               DcbEventStore::Event.new(type: "Old2")
                             ])
    received = []

    subscriber = subscribe_in_thread(DcbEventStore::Query.all, after: appended.last.sequence_position) do |event|
      received << event
      received.size >= 1
    end

    @store.append([DcbEventStore::Event.new(type: "New1")])

    subscriber.join(5)
    assert_equal ["New1"], received.map(&:type)
  end

  def test_subscribe_filtered_query
    received = []
    query = DcbEventStore::Query.new([
                                       DcbEventStore::QueryItem.new(event_types: ["Wanted"])
                                     ])

    subscriber = subscribe_in_thread(query, after: 0) do |event|
      received << event
      received.size >= 1
    end

    @store.append([DcbEventStore::Event.new(type: "Ignored")])
    @store.append([DcbEventStore::Event.new(type: "Wanted")])

    subscriber.join(5)
    assert_equal 1, received.size
    assert_equal "Wanted", received[0].type
  end

  # Tag filtering runs through the event_tags index on the subscriber's own
  # connection, so a live delivery must see the tag rows the appending
  # connection wrote.
  def test_subscribe_filtered_by_tag
    received = []
    query = DcbEventStore::Query.new([
                                       DcbEventStore::QueryItem.new(event_types: [], tags: ["course:c1"])
                                     ])

    subscriber = subscribe_in_thread(query, after: 0) do |event|
      received << event
      received.size >= 1
    end

    @store.append([DcbEventStore::Event.new(type: "A", tags: ["course:c2"])])
    @store.append([DcbEventStore::Event.new(type: "A", tags: ["course:c1"])])

    subscriber.join(5)
    assert_equal 1, received.size
    assert_equal ["course:c1"], received[0].tags
  end

  def test_subscribe_emits_per_event_lag_instrumentation
    @store.append([DcbEventStore::Event.new(type: "Old")])

    seen = Queue.new
    with_subscribe_instrumentation(seen) do
      run_subscriber(expected: 2)
    end

    emitted = drain(seen)
    assert_equal(%i[catch_up live], emitted.map { |e| e.payload[:phase] })
    assert_equal "DcbEventStore::SqliteStore", emitted[0].payload[:store]
    assert_equal([1, 2], emitted.map { |e| e.payload[:sequence_position] })
    emitted.each do |event|
      assert_kind_of Float, event.payload[:lag]
      assert_operator event.payload[:lag].abs, :<, 60
    end
  end

  def test_subscribe_emits_batched_lag_instrumentation
    @store.append([DcbEventStore::Event.new(type: "Old1")])
    @store.append([DcbEventStore::Event.new(type: "Old2")])

    seen = Queue.new
    with_subscribe_instrumentation(seen) do
      run_subscriber(expected: 3, subscribe_instrumentation: :batch)
    end

    emitted = drain(seen)
    assert_equal(%i[catch_up live], emitted.map { |e| e.payload[:phase] })

    catch_up = emitted[0].payload
    assert_equal 2, catch_up[:event_count]
    assert_equal 2, catch_up[:last_position]
    assert_kind_of Float, catch_up[:max_lag]

    live = emitted[1].payload
    assert_equal 1, live[:event_count]
    assert_equal 3, live[:last_position]
  end

  # The PG version asserts the connection survives UNLISTEN in the ensure
  # block; SQLite has nothing to unlisten, but the subscription must still
  # leave its connection usable.
  def test_subscribe_leaves_the_connection_usable_after_the_block_raises
    store = second_connection_store

    # Need an event so catch-up yields and triggers the raise.
    @store.append([DcbEventStore::Event.new(type: "Trigger")])

    assert_raises(RuntimeError) do
      store.subscribe(DcbEventStore::Query.all, after: 0) { |_event| raise "boom" }
    end

    assert_equal 1, store.read(DcbEventStore::Query.all).to_a.size
  end

  # --- the polling hook itself ---

  # Another connection's commit moves PRAGMA data_version, which is what wakes
  # a subscriber holding its own connection. The wake-up then takes that
  # reading as its new baseline, so the same commit cannot wake it twice.
  def test_wait_for_append_returns_once_another_connection_appends
    store = second_connection_store
    store.send(:listen)

    @store.append([DcbEventStore::Event.new(type: "A")])

    assert wait_in_thread(store).join(5), "expected #wait_for_append to return after another connection's append"

    waiter = wait_in_thread(store)
    refute waiter.join(POLL_INTERVAL * 5), "expected the wake-up to have refreshed the baseline"
  ensure
    waiter&.kill
  end

  # A store that appends and subscribes over one connection sees nothing in
  # data_version (own commits never move it), so the wake-up has to come from
  # that connection's own change counter. No further write follows, so the
  # wait can only end because the append itself was noticed -- and only once,
  # the reading being the new baseline.
  def test_wait_for_append_returns_after_an_append_on_the_same_connection
    store = DcbEventStore::SqliteStore.new(@db, poll_interval: POLL_INTERVAL)
    store.send(:listen)
    store.append([DcbEventStore::Event.new(type: "A", tags: ["t:1"])])

    assert wait_in_thread(store).join(5), "expected #wait_for_append to notice this connection's own append"

    waiter = wait_in_thread(store)
    refute waiter.join(POLL_INTERVAL * 5), "expected the wake-up to have refreshed the baseline"
  ensure
    waiter&.kill
  end

  # The poll interval is the promise not to hammer the database: a wake-up
  # costs one interval even when there is already something to read.
  def test_wait_for_append_sleeps_at_least_one_poll_interval
    store = second_connection_store
    store.send(:listen)
    @store.append([DcbEventStore::Event.new(type: "A")])

    elapsed = nil
    waiter = Thread.new do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      store.send(:wait_for_append)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    end

    assert waiter.join(5)
    assert_operator elapsed, :>=, POLL_INTERVAL
  ensure
    waiter&.kill
  end

  # Nothing was written, so the hook keeps sleeping instead of returning and
  # spinning the subscribe loop on empty reads.
  def test_wait_for_append_keeps_waiting_while_nothing_is_written
    store = second_connection_store
    store.send(:listen)

    waiter = wait_in_thread(store)
    refute waiter.join(POLL_INTERVAL * 5), "expected #wait_for_append to still be waiting"

    @store.append([DcbEventStore::Event.new(type: "A")])
    assert waiter.join(5), "expected #wait_for_append to return after the append"
  ensure
    waiter&.kill
  end

  # Reads are not changes: a subscriber polling an idle database must not wake
  # itself up with its own catch-up or live reads.
  def test_wait_for_append_ignores_reads_on_its_own_connection
    @store.append([DcbEventStore::Event.new(type: "A", tags: ["t:1"])])
    store = second_connection_store
    store.send(:listen)
    store.read(DcbEventStore::Query.all).to_a

    waiter = wait_in_thread(store)
    refute waiter.join(POLL_INTERVAL * 5), "expected a read not to count as a change"

    @store.append([DcbEventStore::Event.new(type: "B")])
    assert waiter.join(5)
  ensure
    waiter&.kill
  end

  def test_poll_interval_is_configurable_and_defaults_to_a_tenth_of_a_second
    assert_in_delta 0.1, DcbEventStore::SqliteStore.new(@db).poll_interval
    assert_in_delta POLL_INTERVAL, DcbEventStore::SqliteStore.new(@db, poll_interval: POLL_INTERVAL).poll_interval
  end

  private

  def wait_in_thread(store)
    Thread.new { store.send(:wait_for_append) }
  end

  # A second store on its own connection to the same file, closed on teardown.
  def second_connection_store
    db = SqliteDatabaseHelper.connection(@db_path)
    @extra_dbs << db
    DcbEventStore::SqliteStore.new(db, poll_interval: POLL_INTERVAL)
  end

  # Subscribes on its own connection in a background thread. The block returns
  # truthy once it has seen enough events, which breaks out of the (otherwise
  # endless) subscribe loop. Returns once the subscriber is polling, so an
  # append by the caller cannot land before the subscription is live.
  def subscribe_in_thread(query, after: nil, **options, &block)
    ready = Queue.new
    thread = Thread.new do
      db = SqliteDatabaseHelper.connection(@db_path)
      store = DcbEventStore::SqliteStore.new(db, poll_interval: POLL_INTERVAL, **options)
      signal_when_listening(store, ready)
      store.subscribe(query, after: after) do |event|
        break if block.call(event)
      end
    ensure
      db&.close
    end
    assert ready.pop(timeout: 5), "subscriber never started listening"
    thread
  end

  # Wraps #listen on this one store so a test can wait until the subscribe
  # loop reached its first poll (catch-up delivered, baseline recorded). Only
  # the instance is touched, so the store's class -- which instrumentation
  # payloads report -- stays SqliteStore.
  def signal_when_listening(store, ready)
    store.singleton_class.prepend(Module.new do
      define_method(:listen) do
        super()
        ready << :listening
      end
      private :listen
    end)
    store
  end

  def with_subscribe_instrumentation(seen)
    previous = DcbEventStore.instrumentation
    DcbEventStore.instrumentation = DcbEventStore::Notifications.new
    DcbEventStore.instrumentation.subscribe("subscribe.dcb") { |event| seen << event }
    yield
  ensure
    DcbEventStore.instrumentation = previous
  end

  # Subscribes on a separate connection, appends a live event once the
  # subscriber is caught up, and joins after `expected` deliveries.
  def run_subscriber(expected:, subscribe_instrumentation: :event)
    received = []
    subscriber = subscribe_in_thread(
      DcbEventStore::Query.all, after: 0, subscribe_instrumentation: subscribe_instrumentation
    ) do |event|
      received << event
      received.size >= expected
    end

    @store.append([DcbEventStore::Event.new(type: "LiveEvent")])
    subscriber.join(5)
    assert_equal expected, received.size
  end

  def drain(queue)
    events = []
    events << queue.pop until queue.empty?
    events
  end
end
