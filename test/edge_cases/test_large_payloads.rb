require_relative "../test_helper"
require_relative "../support/database"

# Tests for handling large payloads and performance
class TestLargePayloads < Minitest::Test
  cover "DcbEventStore::Store*"

  include DatabaseHelper

  def setup
    setup_db
  end

  def teardown
    teardown_db
  end

  # --- Large data payloads ---

  def test_large_data_payload
    # Create a large data payload (just under typical limits)
    large_string = "x" * 500_000 # 500KB string
    data = { content: large_string, metadata: { size: large_string.length } }

    event = DcbEventStore::Event.new(type: "LargePayload", data: data, tags: ["large:data"])
    result = @store.append([event])
    assert_equal 1, result.size

    read_events = @store.read(DcbEventStore::Query.all).to_a
    assert_equal large_string, read_events[0].data[:content]
    assert_equal large_string.length, read_events[0].data[:metadata][:size]
  end

  def test_data_with_many_fields
    # Create data with many fields
    data = {}
    100.times do |i|
      data[:"field_#{i}"] = "value_#{i}"
    end

    event = DcbEventStore::Event.new(type: "ManyFields", data: data, tags: ["many:fields"])
    result = @store.append([event])
    assert_equal 1, result.size

    # Data round-trips with symbol keys (the store reads with symbolize_names).
    read_events = @store.read(DcbEventStore::Query.all).to_a
    assert_equal "value_50", read_events[0].data[:field_50]
    assert_equal 100, read_events[0].data.keys.size
  end

  def test_data_with_deep_nesting
    # Create deeply nested data
    data = { level1: { level2: { level3: { level4: { level5: "deep value" } } } } }

    event = DcbEventStore::Event.new(type: "DeepNesting", data: data, tags: ["deep:nesting"])
    result = @store.append([event])
    assert_equal 1, result.size

    read_events = @store.read(DcbEventStore::Query.all).to_a
    assert_equal "deep value", read_events[0].data.dig(:level1, :level2, :level3, :level4, :level5)
  end

  def test_data_with_large_array
    # Create data with a large array
    data = { items: (1..1000).map { |i| { id: i, name: "Item #{i}" } } }

    event = DcbEventStore::Event.new(type: "LargeArray", data: data, tags: ["large:array"])
    result = @store.append([event])
    assert_equal 1, result.size

    read_events = @store.read(DcbEventStore::Query.all).to_a
    assert_equal 1000, read_events[0].data[:items].size
    assert_equal "Item 500", read_events[0].data[:items][499][:name]
  end

  # --- Many tags ---

  def test_many_tags
    # Create an event with many tags
    tags = (1..50).map { |i| "tag:#{i}" }
    event = DcbEventStore::Event.new(type: "ManyTags", data: { count: 50 }, tags: tags)
    result = @store.append([event])
    assert_equal 1, result.size

    read_events = @store.read(DcbEventStore::Query.all).to_a
    assert_equal 50, read_events[0].tags.size
    assert_includes read_events[0].tags, "tag:25"
  end

  def test_query_with_many_tags
    # Create events with different tags
    10.times do |i|
      event = DcbEventStore::Event.new(type: "Event", data: { id: i }, tags: ["group:#{i % 5}"])
      @store.append([event])
    end

    # Query for one tag group
    query = DcbEventStore::Query.new([
                                       DcbEventStore::QueryItem.new(event_types: [], tags: ["group:0"])
                                     ])
    events = @store.read(query).to_a
    assert_equal 2, events.size # group:0 appears for i=0 and i=5
  end

  # --- Long strings in various fields ---

  def test_long_string_in_data_value
    long_string = "a" * 100_000
    data = { long_value: long_string }
    event = DcbEventStore::Event.new(type: "LongValue", data: data, tags: ["long:value"])
    result = @store.append([event])
    assert_equal 1, result.size

    read_events = @store.read(DcbEventStore::Query.all).to_a
    assert_equal long_string, read_events[0].data[:long_value]
  end

  def test_long_string_in_data_key
    long_key = "key_#{'x' * 200}"
    data = { long_key => "value" }
    event = DcbEventStore::Event.new(type: "LongKey", data: data, tags: ["long:key"])
    result = @store.append([event])
    assert_equal 1, result.size

    # Keys come back as symbols (the store reads with symbolize_names).
    read_events = @store.read(DcbEventStore::Query.all).to_a
    assert_equal "value", read_events[0].data[long_key.to_sym]
  end

  # --- Batch operations with large payloads ---

  def test_batch_append_large_events
    events = 10.times.map do |i|
      data = { id: i, content: "x" * 50_000 } # 50KB per event
      DcbEventStore::Event.new(type: "BatchEvent", data: data, tags: ["batch:#{i}"])
    end

    result = @store.append(events)
    assert_equal 10, result.size

    read_events = @store.read(DcbEventStore::Query.all).to_a
    assert_equal 10, read_events.size
    assert_equal "x" * 50_000, read_events[5].data[:content]
  end

  def test_batch_read_large_result
    # Insert many events
    100.times do |i|
      event = DcbEventStore::Event.new(type: "Event", data: { id: i }, tags: ["all"])
      @store.append([event])
    end

    # Read all events
    all_events = @store.read(DcbEventStore::Query.all).to_a
    assert_equal 100, all_events.size
  end
end
