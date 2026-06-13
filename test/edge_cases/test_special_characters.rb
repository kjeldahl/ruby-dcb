require_relative "../test_helper"
require_relative "../support/database"

# Tests for handling special characters in event data
class TestSpecialCharacters < Minitest::Test
  cover "DcbEventStore::Store*"

  include DatabaseHelper

  def setup
    setup_db
  end

  def teardown
    teardown_db
  end

  # --- Tag special characters ---

  def test_tags_with_colons
    event = DcbEventStore::Event.new(type: "OrderCreated", tags: ["order:123", "customer:alice"])
    result = @store.append([event])
    assert_equal 1, result.size

    read_events = @store.read(DcbEventStore::Query.new([
                                                         DcbEventStore::QueryItem.new(event_types: [],
                                                                                      tags: ["order:123"])
                                                       ])).to_a
    assert_equal 1, read_events.size
    assert_equal "OrderCreated", read_events[0].type
  end

  def test_tags_with_hyphens
    event = DcbEventStore::Event.new(type: "OrderCreated", tags: %w[order-123 high-priority])
    result = @store.append([event])
    assert_equal 1, result.size

    read_events = @store.read(DcbEventStore::Query.new([
                                                         DcbEventStore::QueryItem.new(event_types: [],
                                                                                      tags: ["order-123"])
                                                       ])).to_a
    assert_equal 1, read_events.size
  end

  def test_tags_with_underscores
    event = DcbEventStore::Event.new(type: "OrderCreated", tags: %w[order_123 internal_use])
    result = @store.append([event])
    assert_equal 1, result.size

    read_events = @store.read(DcbEventStore::Query.new([
                                                         DcbEventStore::QueryItem.new(event_types: [],
                                                                                      tags: ["order_123"])
                                                       ])).to_a
    assert_equal 1, read_events.size
  end

  def test_tags_with_dots
    event = DcbEventStore::Event.new(type: "OrderCreated", tags: ["order.123", "v1.0"])
    result = @store.append([event])
    assert_equal 1, result.size

    read_events = @store.read(DcbEventStore::Query.new([
                                                         DcbEventStore::QueryItem.new(event_types: [],
                                                                                      tags: ["order.123"])
                                                       ])).to_a
    assert_equal 1, read_events.size
  end

  def test_tags_with_slashes
    event = DcbEventStore::Event.new(type: "OrderCreated", tags: ["tenant/acme", "region/us-east"])
    result = @store.append([event])
    assert_equal 1, result.size

    read_events = @store.read(DcbEventStore::Query.new([
                                                         DcbEventStore::QueryItem.new(event_types: [],
                                                                                      tags: ["tenant/acme"])
                                                       ])).to_a
    assert_equal 1, read_events.size
  end

  def test_tags_with_unicode
    event = DcbEventStore::Event.new(type: "OrderCreated", tags: ["customer:alice", "region:北京"])
    result = @store.append([event])
    assert_equal 1, result.size

    read_events = @store.read(DcbEventStore::Query.new([
                                                         DcbEventStore::QueryItem.new(event_types: [],
                                                                                      tags: ["region:北京"])
                                                       ])).to_a
    assert_equal 1, read_events.size
  end

  def test_tags_with_emoji
    event = DcbEventStore::Event.new(type: "OrderCreated", tags: ["priority:🔥", "status:✅"])
    result = @store.append([event])
    assert_equal 1, result.size

    read_events = @store.read(DcbEventStore::Query.new([
                                                         DcbEventStore::QueryItem.new(event_types: [],
                                                                                      tags: ["priority:🔥"])
                                                       ])).to_a
    assert_equal 1, read_events.size
  end

  def test_tags_with_spaces
    # Spaces are allowed in tags
    event = DcbEventStore::Event.new(type: "OrderCreated", tags: ["customer name:alice", "order id:123"])
    result = @store.append([event])
    assert_equal 1, result.size

    read_events = @store.read(DcbEventStore::Query.new([
                                                         DcbEventStore::QueryItem.new(event_types: [],
                                                                                      tags: ["customer name:alice"])
                                                       ])).to_a
    assert_equal 1, read_events.size
  end

  # --- Event type special characters ---

  def test_event_type_with_colons
    event = DcbEventStore::Event.new(type: "Order:Created", data: {id: "123"}, tags: ["order:123"])
    result = @store.append([event])
    assert_equal 1, result.size

    read_events = @store.read(DcbEventStore::Query.new([
                                                         DcbEventStore::QueryItem.new(event_types: ["Order:Created"])
                                                       ])).to_a
    assert_equal 1, read_events.size
    assert_equal "Order:Created", read_events[0].type
  end

  def test_event_type_with_hyphens
    event = DcbEventStore::Event.new(type: "Order-Created", data: {id: "123"}, tags: ["order:123"])
    result = @store.append([event])
    assert_equal 1, result.size

    read_events = @store.read(DcbEventStore::Query.new([
                                                         DcbEventStore::QueryItem.new(event_types: ["Order-Created"])
                                                       ])).to_a
    assert_equal 1, read_events.size
    assert_equal "Order-Created", read_events[0].type
  end

  def test_event_type_with_underscores
    event = DcbEventStore::Event.new(type: "Order_Created", data: {id: "123"}, tags: ["order:123"])
    result = @store.append([event])
    assert_equal 1, result.size

    read_events = @store.read(DcbEventStore::Query.new([
                                                         DcbEventStore::QueryItem.new(event_types: ["Order_Created"])
                                                       ])).to_a
    assert_equal 1, read_events.size
    assert_equal "Order_Created", read_events[0].type
  end

  # --- Data special characters ---

  def test_data_with_unicode
    data = { customer_name: "Alice", notes: "客户订单" }
    event = DcbEventStore::Event.new(type: "OrderCreated", data: data, tags: ["order:123"])
    result = @store.append([event])
    assert_equal 1, result.size

    read_events = @store.read(DcbEventStore::Query.all).to_a
    assert_equal "客户订单", read_events[0].data[:notes]
  end

  def test_data_with_emoji
    data = { status: "✅", priority: "🔥" }
    event = DcbEventStore::Event.new(type: "OrderCreated", data: data, tags: ["order:123"])
    result = @store.append([event])
    assert_equal 1, result.size

    read_events = @store.read(DcbEventStore::Query.all).to_a
    assert_equal "✅", read_events[0].data[:status]
    assert_equal "🔥", read_events[0].data[:priority]
  end

  def test_data_with_special_json_characters
    data = { text: "Line 1\nLine 2", tab: "Col1\tCol2", quote: 'He said "hello"' }
    event = DcbEventStore::Event.new(type: "OrderCreated", data: data, tags: ["order:123"])
    result = @store.append([event])
    assert_equal 1, result.size

    read_events = @store.read(DcbEventStore::Query.all).to_a
    assert_equal "Line 1\nLine 2", read_events[0].data[:text]
    assert_equal "Col1\tCol2", read_events[0].data[:tab]
    assert_equal 'He said "hello"', read_events[0].data[:quote]
  end

  def test_data_with_nested_structure
    data = {
      order: {
        id: "123",
        items: [
          { name: "Item 1", price: 10.99 },
          { name: "Item 2", price: 20.50 }
        ],
        metadata: {
          created_at: Time.now.iso8601,
          updated_at: Time.now.iso8601
        }
      }
    }
    event = DcbEventStore::Event.new(type: "OrderCreated", data: data, tags: ["order:123"])
    result = @store.append([event])
    assert_equal 1, result.size

    read_events = @store.read(DcbEventStore::Query.all).to_a
    assert_equal "Item 1", read_events[0].data[:order][:items][0][:name]
    assert_equal 10.99, read_events[0].data[:order][:items][0][:price]
  end

  # --- Empty and nil values ---

  def test_empty_tags
    event = DcbEventStore::Event.new(type: "OrderCreated", data: {id: "123"}, tags: [])
    result = @store.append([event])
    assert_equal 1, result.size

    read_events = @store.read(DcbEventStore::Query.all).to_a
    assert_equal [], read_events[0].tags
  end

  def test_empty_data
    event = DcbEventStore::Event.new(type: "OrderCreated", data: {}, tags: ["order:123"])
    result = @store.append([event])
    assert_equal 1, result.size

    read_events = @store.read(DcbEventStore::Query.all).to_a
    assert_equal({}, read_events[0].data)
  end

  def test_nil_data_becomes_empty_hash
    event = DcbEventStore::Event.new(type: "OrderCreated", data: nil, tags: ["order:123"])
    result = @store.append([event])
    assert_equal 1, result.size

    read_events = @store.read(DcbEventStore::Query.all).to_a
    # NOTE: nil data is stored as {} in the database
    assert_equal({}, read_events[0].data)
  end
end
