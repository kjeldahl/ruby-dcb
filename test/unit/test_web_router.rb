require_relative "../test_helper"
require "dcb_event_store/web"

class TestWebRouter < Minitest::Test
  cover "DcbEventStore::Web::Router*"

  # Fake read model - records the args the router computes and returns canned
  # data, so routing/param logic is tested with no live PG.
  class FakeReadModel
    attr_reader :page_args, :count_query, :found_position, :snapshot_args, :found_key

    def initialize(events: [], types: [], found: nil, **snapshots)
      @events = events
      @types = types
      @found = found
      @snapshots = snapshots[:snapshots]
      @snapshot = snapshots[:snapshot]
      @head = snapshots[:head]
    end

    def snapshots?
      !@snapshots.nil?
    end

    def head_position
      @head
    end

    def snapshot_page(match:, limit:, offset:)
      @snapshot_args = { match: match, limit: limit, offset: offset }
      @snapshots
    end

    def snapshot_count(**)
      @snapshots.size
    end

    def find_snapshot(key)
      @found_key = key
      @snapshot
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

  def call(path, query = "", namespaces: [nil], **)
    read = FakeReadModel.new(**)
    asked = []
    read_models = lambda { |namespace|
      asked << namespace
      read
    }
    router = DcbEventStore::Web::Router.new(read_models, namespaces: namespaces)
    status, _headers, body = router.call(env(path, query))
    [status, body.join, read, asked]
  end

  def record(key: "s/v1/x", position: 3, state: { n: 1 })
    DcbEventStore::Web::ReadModel::SnapshotRecord.new(key: key, position: position,
                                                      updated_at: Time.at(0).utc, state: state)
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
    _status, headers, = DcbEventStore::Web::Router.new(->(_ns) { FakeReadModel.new(events: [event]) }).call(env("/"))
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

  # --- namespaces ---

  def test_default_namespace_without_ns_param
    _status, _body, _read, asked = call("/", namespaces: [nil, "billing"])
    assert_equal [nil], asked
  end

  def test_ns_param_selects_namespace
    status, _body, _read, asked = call("/", "ns=billing", namespaces: [nil, "billing"])
    assert_equal 200, status
    assert_equal ["billing"], asked
  end

  def test_unknown_namespace_is_404_without_reading
    status, _body, _read, asked = call("/", "ns=nope", namespaces: [nil, "billing"])
    assert_equal 404, status
    assert_empty asked
  end

  def test_first_namespace_when_default_is_not_offered
    _status, _body, _read, asked = call("/", namespaces: %w[billing shipping])
    assert_equal ["billing"], asked
  end

  def test_namespaces_may_be_a_callable
    read = FakeReadModel.new
    router = DcbEventStore::Web::Router.new(->(_ns) { read }, namespaces: -> { [nil, "billing"] })
    status, _headers, body = router.call(env("/", "ns=billing"))
    assert_equal 200, status
    assert_includes body.join, "billing"
  end

  def test_namespace_switcher_lists_every_namespace
    _status, body, = call("/", namespaces: [nil, "billing"])
    assert_includes body, "<option value=\"billing\">billing</option>"
    assert_includes body, "default"
  end

  def test_no_switcher_for_a_single_default_namespace
    _status, body, = call("/")
    refute_includes body, "Switch"
  end

  def test_links_keep_the_namespace
    _status, body, = call("/", "ns=billing", events: [event(position: 4)], namespaces: [nil, "billing"])
    assert_includes body, "/events/4?ns=billing"
  end

  # --- snapshots ---

  def test_snapshot_list_renders
    status, body, read = call("/snapshots", "q=course&per_page=10&page=2", snapshots: [record], head: 9)
    assert_equal 200, status
    assert_equal({ match: "course", limit: 10, offset: 10 }, read.snapshot_args)
    assert_includes body, "s/v1/x"
    assert_includes body, "log head at #9"
  end

  def test_snapshot_list_without_snapshots_table
    status, body, = call("/snapshots")
    assert_equal 200, status
    assert_includes body, "No snapshots table"
  end

  def test_snapshot_list_in_namespace
    _status, _body, _read, asked = call("/snapshots", "ns=billing", snapshots: [], namespaces: [nil, "billing"])
    assert_equal ["billing"], asked
  end

  def test_snapshot_detail_found
    status, body, read = call("/snapshot", "key=s%2Fv1%2Fx",
                              snapshots: [], snapshot: record, found: event(position: 3), head: 5)
    assert_equal 200, status
    assert_equal "s/v1/x", read.found_key
    assert_includes body, "State"
    assert_includes body, "&quot;n&quot;: 1"
  end

  def test_snapshot_detail_missing_is_404
    status, = call("/snapshot", "key=nope", snapshots: [])
    assert_equal 404, status
  end

  def test_snapshot_detail_without_table_is_404
    status, = call("/snapshot", "key=x")
    assert_equal 404, status
  end
end
