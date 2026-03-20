require_relative "../test_helper"
require_relative "../support/database"

class TestReadFrom < Minitest::Test
  include DatabaseHelper

  def setup
    setup_db
  end

  def teardown
    teardown_db
  end

  def test_read_from_returns_events_after_position
    10.times { |i| @store.append([DcbEventStore::Event.new(type: "E#{i}")]) }

    events = @store.read_from(DcbEventStore::Query.all, after: 5).to_a
    assert_equal 5, events.size
    assert(events.all? { |e| e.sequence_position > 5 })
  end

  def test_read_from_with_filtered_query
    5.times { @store.append([DcbEventStore::Event.new(type: "A")]) }
    5.times { @store.append([DcbEventStore::Event.new(type: "B")]) }

    query = DcbEventStore::Query.new([
                                       DcbEventStore::QueryItem.new(event_types: ["A"])
                                     ])
    events = @store.read_from(query, after: 3).to_a
    assert_equal 2, events.size
    assert(events.all? { |e| e.type == "A" && e.sequence_position > 3 })
  end

  def test_read_from_zero_returns_all
    3.times { @store.append([DcbEventStore::Event.new(type: "X")]) }
    events = @store.read_from(DcbEventStore::Query.all, after: 0).to_a
    assert_equal 3, events.size
  end

  def test_read_from_beyond_last_returns_empty
    3.times { @store.append([DcbEventStore::Event.new(type: "X")]) }
    events = @store.read_from(DcbEventStore::Query.all, after: 100).to_a
    assert_empty events
  end
end
