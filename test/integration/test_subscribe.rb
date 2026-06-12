require_relative "../test_helper"
require_relative "../support/database"

class TestSubscribe < Minitest::Test
  cover "DcbEventStore::Store#subscribe"
  # The delivery helpers' return value (last delivered position) drives the
  # live loop's resume position, which only PG subscribe tests can observe.
  cover "DcbEventStore::StoreInstrumentation*"

  include DatabaseHelper

  def setup
    setup_db
  end

  def teardown
    teardown_db
  end

  def test_subscribe_receives_appended_event
    received = []

    subscriber = Thread.new do
      conn = DatabaseHelper.connection
      store = DcbEventStore::Store.new(conn)
      store.subscribe(DcbEventStore::Query.all, after: 0) do |event|
        received << event
        break if received.size >= 1
      end
    ensure
      conn&.close
    end

    sleep 0.1

    @store.append([DcbEventStore::Event.new(type: "LiveEvent")])

    subscriber.join(5)
    assert_equal 1, received.size
    assert_equal "LiveEvent", received[0].type
  end

  def test_subscribe_catches_up_then_live
    @store.append([DcbEventStore::Event.new(type: "Old1")])
    @store.append([DcbEventStore::Event.new(type: "Old2")])

    received = []

    subscriber = Thread.new do
      conn = DatabaseHelper.connection
      store = DcbEventStore::Store.new(conn)
      store.subscribe(DcbEventStore::Query.all) do |event|
        received << event
        break if received.size >= 3
      end
    ensure
      conn&.close
    end

    sleep 0.1

    @store.append([DcbEventStore::Event.new(type: "New1")])

    subscriber.join(5)
    assert_equal 3, received.size
    assert_equal %w[Old1 Old2 New1], received.map(&:type)
  end

  def test_subscribe_filtered_query
    received = []

    subscriber = Thread.new do
      conn = DatabaseHelper.connection
      store = DcbEventStore::Store.new(conn)
      query = DcbEventStore::Query.new([
                                         DcbEventStore::QueryItem.new(event_types: ["Wanted"])
                                       ])
      store.subscribe(query, after: 0) do |event|
        received << event
        break if received.size >= 1
      end
    ensure
      conn&.close
    end

    sleep 0.1

    @store.append([DcbEventStore::Event.new(type: "Ignored")])
    @store.append([DcbEventStore::Event.new(type: "Wanted")])

    subscriber.join(5)
    assert_equal 1, received.size
    assert_equal "Wanted", received[0].type
  end

  def test_subscribe_emits_per_event_lag_instrumentation
    @store.append([DcbEventStore::Event.new(type: "Old")])

    seen = Queue.new
    with_subscribe_instrumentation(seen) do
      run_subscriber(expected: 2)
    end

    emitted = drain(seen)
    assert_equal(%i[catch_up live], emitted.map { |e| e.payload[:phase] })
    assert_equal "DcbEventStore::Store", emitted[0].payload[:store]
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
    subscriber = Thread.new do
      conn = DatabaseHelper.connection
      store = DcbEventStore::Store.new(conn, subscribe_instrumentation: subscribe_instrumentation)
      store.subscribe(DcbEventStore::Query.all, after: 0) do |event|
        received << event
        break if received.size >= expected
      end
    ensure
      conn&.close
    end

    sleep 0.1
    @store.append([DcbEventStore::Event.new(type: "LiveEvent")])
    subscriber.join(5)
    assert_equal expected, received.size
  end

  def drain(queue)
    events = []
    events << queue.pop until queue.empty?
    events
  end

  def test_subscribe_unlisten_on_block_raise
    conn = DatabaseHelper.connection
    store = DcbEventStore::Store.new(conn)

    # Need an event so catch-up yields and triggers the raise
    @store.append([DcbEventStore::Event.new(type: "Trigger")])

    assert_raises(RuntimeError) do
      store.subscribe(DcbEventStore::Query.all, after: 0) do |_event|
        raise "boom"
      end
    end

    # UNLISTEN should have run in ensure block.
    # Verify conn is still usable (not in broken state from leaked LISTEN).
    result = conn.exec("SELECT 1 AS ok")
    assert_equal "1", result[0]["ok"]
  ensure
    conn&.close
  end
end
