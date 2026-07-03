require_relative "../test_helper"
require_relative "../support/postgres_database"
require "dcb_event_store/web"
require "rack/mock"

class TestWeb < Minitest::Test
  include PostgresDatabaseHelper

  def setup
    setup_db
    # The store owns @conn (it installs its own result type map); the browser
    # reads over a plain connection, as it does when it borrows the app's.
    @web_conn = PostgresDatabaseHelper.connection
    DcbEventStore::Web.connection = @web_conn
  end

  def teardown
    DcbEventStore::Web.connection = nil
    @web_conn&.close
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

  # --- namespaces ---

  def namespaced_store(name)
    DcbEventStore::PostgresStore::Schema.create!(@web_conn, namespace: name)
    DcbEventStore::PostgresStore.new(PostgresDatabaseHelper.connection, namespace: name)
  end

  def test_discovers_and_browses_namespaces
    seed("DefaultEvent")
    namespaced_store("web_billing").append([DcbEventStore::Event.new(type: "Invoiced")])

    default = get("/")
    assert_includes default.body, "DefaultEvent"
    refute_includes default.body, "Invoiced"
    assert_includes default.body, "web_billing"

    billing = get("/?ns=web_billing")
    assert_includes billing.body, "Invoiced"
    refute_includes billing.body, "DefaultEvent"
    assert_includes billing.body, "/events/1?ns=web_billing"

    assert_includes get("/events/1?ns=web_billing").body, "Invoiced"
  ensure
    DcbEventStore::PostgresStore::Schema.drop!(@web_conn, namespace: "web_billing")
  end

  def test_unknown_namespace_is_404
    assert_equal 404, get("/?ns=nope").status
  end

  def test_configured_namespaces_replace_discovery
    namespaced_store("web_billing")
    DcbEventStore::Web.namespaces = ["web_billing"]
    body = get("/").body
    assert_includes body, "?ns=web_billing"
    assert_equal 404, get("/?ns=web_shipping").status
  ensure
    DcbEventStore::Web.namespaces = nil
    DcbEventStore::PostgresStore::Schema.drop!(@web_conn, namespace: "web_billing")
  end

  # --- snapshots ---

  def snapshots
    DcbEventStore::Snapshots::PostgresSnapshotStore.new(PostgresDatabaseHelper.connection)
  end

  def test_snapshot_list_and_detail
    @web_conn.exec("TRUNCATE projection_snapshots")
    seed("A", "B", "C")
    snapshots.store("course/v1/q", position: 2, state: { seats: 5 })

    list = get("/snapshots")
    assert_equal 200, list.status
    assert_includes list.body, "course/v1/q"
    assert_includes list.body, "log head at #3"

    detail = get("/snapshot?key=course%2Fv1%2Fq")
    assert_equal 200, detail.status
    assert_includes detail.body, "&quot;seats&quot;: 5"
    assert_includes detail.body, "/events/2"
  end

  def test_snapshot_list_filter
    @web_conn.exec("TRUNCATE projection_snapshots")
    snapshots.store("course/v1/q", position: 1, state: {})
    snapshots.store("order/v1/q", position: 2, state: {})

    body = get("/snapshots?q=order").body
    assert_includes body, "order/v1/q"
    refute_includes body, "course/v1/q"
  end

  def test_snapshot_detail_missing_is_404
    assert_equal 404, get("/snapshot?key=nope").status
  end

  def test_snapshots_in_a_namespace
    namespaced_store("web_billing")
    DcbEventStore::Snapshots::PostgresSnapshotStore.new(PostgresDatabaseHelper.connection, namespace: "web_billing")
                                                   .store("web_billing/a/v1/x", position: 1, state: { ok: true })

    assert_includes get("/snapshots?ns=web_billing").body, "web_billing/a/v1/x"
    assert_includes get("/snapshot?ns=web_billing&key=web_billing%2Fa%2Fv1%2Fx").body, "&quot;ok&quot;: true"
  ensure
    DcbEventStore::PostgresStore::Schema.drop!(@web_conn, namespace: "web_billing")
  end

  def test_snapshot_page_without_table
    @web_conn.exec("DROP TABLE projection_snapshots")
    assert_includes get("/snapshots").body, "No snapshots table"
    assert_equal 404, get("/snapshot?key=x").status
  ensure
    DcbEventStore::PostgresStore::Schema.create!(@web_conn)
  end
end
