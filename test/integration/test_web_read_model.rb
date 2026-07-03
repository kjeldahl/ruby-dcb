require_relative "../test_helper"
require_relative "../support/database"
require "dcb_event_store/web/read_model"

class TestWebReadModel < Minitest::Test
  cover "DcbEventStore::Web::ReadModel*"

  include DatabaseHelper

  def setup
    setup_db
    @read = DcbEventStore::Web::ReadModel.new(@conn)
  end

  def teardown
    teardown_db
  end

  def event(type, data: {}, tags: [])
    DcbEventStore::Event.new(type: type, data: data, tags: tags)
  end

  def seed(*types)
    @store.append(types.map { |t| event(t) })
  end

  # --- count ---

  def test_count_empty
    assert_equal 0, @read.count
  end

  def test_count_all
    seed("A", "B", "C")
    assert_equal 3, @read.count
  end

  def test_count_filtered_by_type
    seed("A", "B", "A")
    query = DcbEventStore::Query.new(DcbEventStore::QueryItem.new(event_types: ["A"]))
    assert_equal 2, @read.count(query)
  end

  # --- head_position ---

  def test_head_position_nil_when_empty
    assert_nil @read.head_position
  end

  def test_head_position_is_max_sequence
    seed("A", "B", "C")
    assert_equal 3, @read.head_position
  end

  # --- page (newest first) ---

  def test_page_returns_newest_first
    seed("A", "B", "C")
    positions = @read.page(limit: 10).map(&:sequence_position)
    assert_equal [3, 2, 1], positions
  end

  def test_page_respects_limit_and_offset
    seed("A", "B", "C", "D", "E")
    page = @read.page(limit: 2, offset: 2)
    assert_equal [3, 2], page.map(&:sequence_position)
  end

  def test_page_returns_sequenced_events
    seed("A")
    e = @read.page(limit: 1).first
    assert_instance_of DcbEventStore::SequencedEvent, e
    assert_equal "A", e.type
  end

  def test_page_filtered_by_query
    seed("A", "B", "A")
    query = DcbEventStore::Query.new(DcbEventStore::QueryItem.new(event_types: ["A"]))
    assert_equal %w[A A], @read.page(query: query, limit: 10).map(&:type)
  end

  # --- event_types ---

  def test_event_types_distinct_sorted
    seed("Beta", "Alpha", "Beta")
    assert_equal %w[Alpha Beta], @read.event_types
  end

  def test_event_types_empty
    assert_empty @read.event_types
  end

  # --- find ---

  def test_find_by_position
    seed("A", "B")
    e = @read.find(2)
    assert_equal "B", e.type
    assert_equal 2, e.sequence_position
  end

  def test_find_missing_returns_nil
    assert_nil @read.find(999)
  end
end
