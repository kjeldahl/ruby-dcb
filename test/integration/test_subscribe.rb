require_relative "../test_helper"
require_relative "../support/database"

class TestSubscribe < Minitest::Test
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
end
