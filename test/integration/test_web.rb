require_relative "../test_helper"
require_relative "../support/database"
require "dcb_event_store/web"
require "rack/mock"

class TestWeb < Minitest::Test
  include DatabaseHelper

  def setup
    setup_db
    DcbEventStore::Web.connection = @conn
  end

  def teardown
    DcbEventStore::Web.connection = nil
    teardown_db
  end

  def get(path)
    Rack::MockRequest.new(DcbEventStore::Web).get(path)
  end

  def seed(*types)
    @store.append(types.map { |t| DcbEventStore::Event.new(type: t) })
  end

  # --- list ---

  def test_list_ok_and_html
    seed("OrderPlaced")
    res = get("/")
    assert_equal 200, res.status
    assert_includes res.headers["content-type"], "text/html"
    assert_includes res.body, "OrderPlaced"
  end

  def test_list_empty_state
    res = get("/")
    assert_equal 200, res.status
    assert_includes res.body, "No events"
  end

  def test_list_newest_first
    seed("Alpha", "Bravo")
    body = get("/").body
    assert_operator body.index("<td>Bravo</td>"), :<, body.index("<td>Alpha</td>")
  end

  # --- filtering ---

  def test_filter_by_type
    seed("Alpha", "Bravo")
    body = get("/?type=Alpha").body
    assert_includes body, "<td>Alpha</td>"
    refute_includes body, "<td>Bravo</td>"
  end

  def test_filter_by_tag
    @store.append(DcbEventStore::Event.new(type: "Alpha", tags: ["order:1"]))
    @store.append(DcbEventStore::Event.new(type: "Bravo", tags: ["order:2"]))
    body = get("/?tag=order:1").body
    assert_includes body, "order:1"
    refute_includes body, "order:2"
  end

  def test_tags_are_clickable_filter_links
    @store.append(DcbEventStore::Event.new(type: "Alpha", tags: ["order:1"]))
    body = get("/").body
    assert_includes body, %(<a class="tag" href="/?tag=order%3A1")
  end

  def test_clicking_a_tag_adds_it_to_the_active_filter
    @store.append(DcbEventStore::Event.new(type: "Alpha", tags: %w[a b]))
    body = get("/?tag=a").body
    # The other tag on the row links to the accumulated filter, not a fresh one.
    assert_includes body, %(href="/?tag=a&tag=b")
  end

  def test_multiple_tags_filter_with_and
    @store.append(DcbEventStore::Event.new(type: "Both", tags: %w[a b]))
    @store.append(DcbEventStore::Event.new(type: "OnlyA", tags: ["a"]))
    body = get("/?tag=a&tag=b").body
    assert_includes body, "<td>Both</td>"
    refute_includes body, "<td>OnlyA</td>"
  end

  def test_active_tag_shows_removable_chip
    @store.append(DcbEventStore::Event.new(type: "Alpha", tags: ["order:1"]))
    body = get("/?tag=order:1").body
    assert_includes body, %(<a class="chip" href="/")
    assert_includes body, "&times;"
    assert_includes body, "clear all"
  end

  def test_detail_tags_link_to_filter
    @store.append(DcbEventStore::Event.new(type: "OrderPlaced", tags: ["order:1"]))
    body = get("/events/1").body
    assert_includes body, %(<a class="tag" href="/?tag=order%3A1")
  end

  # --- pagination ---

  def test_pagination_offsets_by_page
    seed("Alpha", "Bravo", "Charlie")
    body = get("/?per_page=2&page=2").body
    assert_includes body, "<td>Alpha</td>"
    refute_includes body, "<td>Charlie</td>"
  end

  # --- detail ---

  def test_detail_shows_payload_and_tags
    @store.append(DcbEventStore::Event.new(type: "OrderPlaced", data: { total: 42 }, tags: ["order:1"]))
    res = get("/events/1")
    assert_equal 200, res.status
    assert_includes res.body, "OrderPlaced"
    assert_includes res.body, "42"
    assert_includes res.body, "order:1"
  end

  def test_detail_missing_is_404
    res = get("/events/999")
    assert_equal 404, res.status
  end

  # --- routing ---

  def test_unknown_path_is_404
    res = get("/nope")
    assert_equal 404, res.status
  end

  def test_html_is_escaped
    @store.append(DcbEventStore::Event.new(type: "X", data: { note: "<script>" }))
    body = get("/events/1").body
    refute_includes body, "<script>"
    assert_includes body, "&lt;script&gt;"
  end
end
