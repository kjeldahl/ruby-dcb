require_relative "../test_helper"
require_relative "../support/database"
require "securerandom"

class TestStoreRead < Minitest::Test
  include DatabaseHelper

  def setup
    setup_db
  end

  def teardown
    teardown_db
  end

  def test_read_empty_store
    events = @store.read(DcbEventStore::Query.all).to_a
    assert_empty events
  end

  def test_read_all_returns_all_events
    insert_event(type: "A", data: "{}", tags: ["x:1"])
    insert_event(type: "B", data: "{}", tags: ["y:2"])

    events = @store.read(DcbEventStore::Query.all).to_a
    assert_equal 2, events.size
    assert_equal %w[A B], events.map(&:type)
  end

  def test_read_filters_by_type
    insert_event(type: "A", data: "{}", tags: [])
    insert_event(type: "B", data: "{}", tags: [])

    query = DcbEventStore::Query.new([
      DcbEventStore::QueryItem.new(event_types: ["A"])
    ])
    events = @store.read(query).to_a
    assert_equal 1, events.size
    assert_equal "A", events[0].type
  end

  def test_read_filters_by_tag
    insert_event(type: "A", data: "{}", tags: ["course:c1"])
    insert_event(type: "A", data: "{}", tags: ["course:c2"])

    query = DcbEventStore::Query.new([
      DcbEventStore::QueryItem.new(event_types: ["A"], tags: ["course:c1"])
    ])
    events = @store.read(query).to_a
    assert_equal 1, events.size
    assert_equal ["course:c1"], events[0].tags
  end

  def test_read_tags_must_contain_all
    insert_event(type: "A", data: "{}", tags: ["student:s1", "course:c1"])
    insert_event(type: "A", data: "{}", tags: ["student:s1"])

    query = DcbEventStore::Query.new([
      DcbEventStore::QueryItem.new(event_types: ["A"], tags: ["student:s1", "course:c1"])
    ])
    events = @store.read(query).to_a
    assert_equal 1, events.size
    assert_equal ["student:s1", "course:c1"], events[0].tags
  end

  def test_read_or_across_query_items
    insert_event(type: "A", data: "{}", tags: ["x:1"])
    insert_event(type: "B", data: "{}", tags: ["y:2"])
    insert_event(type: "C", data: "{}", tags: ["z:3"])

    query = DcbEventStore::Query.new([
      DcbEventStore::QueryItem.new(event_types: ["A"]),
      DcbEventStore::QueryItem.new(event_types: ["B"])
    ])
    events = @store.read(query).to_a
    assert_equal 2, events.size
    assert_equal %w[A B], events.map(&:type)
  end

  def test_read_ordered_by_sequence_position
    insert_event(type: "A", data: "{}", tags: [])
    insert_event(type: "B", data: "{}", tags: [])
    insert_event(type: "C", data: "{}", tags: [])

    events = @store.read(DcbEventStore::Query.all).to_a
    positions = events.map(&:sequence_position)
    assert_equal positions.sort, positions
  end

  def test_sequenced_event_types
    insert_event(type: "A", data: '{"x":1}', tags: ["t:1"])

    event = @store.read(DcbEventStore::Query.all).first
    assert_kind_of Integer, event.sequence_position
    assert_kind_of String, event.type
    assert_kind_of Hash, event.data
    assert_kind_of Array, event.tags
    assert_kind_of Time, event.created_at
    assert_equal({x: 1}, event.data)
  end

  def test_event_id_returned_on_read
    event = @store.read(DcbEventStore::Query.all).to_a
    insert_event(type: "A", data: "{}", tags: [])
    event = @store.read(DcbEventStore::Query.all).first
    refute_nil event.id
  end

  private

  def insert_event(type:, data:, tags:)
    tags_literal = "{#{tags.join(",")}}"
    @conn.exec_params(
      "INSERT INTO events (event_id, type, data, tags) VALUES ($1, $2, $3::jsonb, $4::text[])",
      [SecureRandom.uuid, type, data, tags_literal]
    )
  end
end
