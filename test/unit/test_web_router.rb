require_relative "../test_helper"
require "dcb_event_store/web"

class TestWebRouter < Minitest::Test
  cover "DcbEventStore::Web::Router*"

  # Fake read model - records the args the router computes and returns canned
  # data, so routing/param logic is tested with no live PG.
  class FakeReadModel
    attr_reader :page_args, :count_query, :found_position

    def initialize(events: [], types: [], found: nil)
      @events = events
      @types = types
      @found = found
    end

    def page(query:, limit:, offset:)
      @page_args = { query: query, limit: limit, offset: offset }
      @events
    end

    def count(query = DcbEventStore::Query.all)
      @count_query = query
      @events.size
    end

    def event_types
      @types
    end

    def find(position)
      @found_position = position
      @found
    end
  end

  def event(position: 1)
    DcbEventStore::SequencedEvent.new(
      sequence_position: position, type: "A", data: {}, tags: [],
      created_at: Time.at(0), id: "id-#{position}", causation_id: nil,
      correlation_id: nil, schema_version: 1
    )
  end

  def env(path, query = "")
    { "PATH_INFO" => path, "QUERY_STRING" => query }
  end

  def call(path, query = "", **)
    read = FakeReadModel.new(**)
    status, _headers, body = DcbEventStore::Web::Router.new(read).call(env(path, query))
    [status, body.join, read]
  end

  # --- routing ---

  def test_root_renders_list
    status, body, = call("/", events: [event])
    assert_equal 200, status
    assert_includes body, "event(s)"
  end

  def test_empty_path_renders_list
    status, = call("", events: [event])
    assert_equal 200, status
  end

  def test_html_content_type
    _s, _b, = call("/", events: [event])
    _status, headers, = DcbEventStore::Web::Router.new(FakeReadModel.new(events: [event])).call(env("/"))
    assert_equal "text/html; charset=utf-8", headers["content-type"]
  end

  def test_event_detail_found
    status, body, read = call("/events/7", found: event(position: 7))
    assert_equal 200, status
    assert_equal 7, read.found_position
    assert_includes body, "Sequence position"
  end

  def test_event_detail_missing_is_404
    status, = call("/events/7", found: nil)
    assert_equal 404, status
  end

  def test_unknown_path_is_404
    status, = call("/nope")
    assert_equal 404, status
  end

  def test_non_numeric_event_id_is_404
    status, = call("/events/abc")
    assert_equal 404, status
  end

  # --- per_page ---

  def test_default_per_page
    _s, _b, read = call("/", "", events: [event])
    assert_equal 50, read.page_args[:limit]
  end

  def test_per_page_from_param
    _s, _b, read = call("/", "per_page=10", events: [event])
    assert_equal 10, read.page_args[:limit]
  end

  def test_per_page_clamped_to_max
    _s, _b, read = call("/", "per_page=9999", events: [event])
    assert_equal 200, read.page_args[:limit]
  end

  def test_zero_per_page_falls_back_to_default
    _s, _b, read = call("/", "per_page=0", events: [event])
    assert_equal 50, read.page_args[:limit]
  end

  # --- page / offset ---

  def test_default_page_offset_zero
    _s, _b, read = call("/", "", events: [event])
    assert_equal 0, read.page_args[:offset]
  end

  def test_offset_from_page_and_per_page
    _s, _b, read = call("/", "page=3&per_page=10", events: [event])
    assert_equal 20, read.page_args[:offset]
  end

  def test_page_below_one_treated_as_one
    _s, _b, read = call("/", "page=0", events: [event])
    assert_equal 0, read.page_args[:offset]
  end

  # --- query building ---

  def test_no_filter_matches_all
    _s, _b, read = call("/", "", events: [event])
    assert read.page_args[:query].match_all?
  end

  def test_empty_filter_params_match_all
    _s, _b, read = call("/", "type=&tag=", events: [event])
    assert read.page_args[:query].match_all?
  end

  def test_filter_by_type_builds_query_item
    _s, _b, read = call("/", "type=OrderPlaced", events: [event])
    item = read.page_args[:query].items.first
    assert_equal ["OrderPlaced"], item.event_types
    assert_empty item.tags
  end

  def test_filter_by_tag_builds_query_item
    _s, _b, read = call("/", "tag=order:1", events: [event])
    item = read.page_args[:query].items.first
    assert_equal ["order:1"], item.tags
    assert_empty item.event_types
  end

  def test_filter_by_type_and_tag
    _s, _b, read = call("/", "type=A&tag=order:1", events: [event])
    item = read.page_args[:query].items.first
    assert_equal ["A"], item.event_types
    assert_equal ["order:1"], item.tags
  end

  def test_count_uses_same_query_as_page
    _s, _b, read = call("/", "type=A", events: [event])
    assert_equal read.page_args[:query], read.count_query
  end
end
