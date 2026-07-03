require_relative "../test_helper"
require "dcb_event_store/web"

class TestWebView < Minitest::Test
  cover "DcbEventStore::Web::View*"

  def view(assigns = {})
    DcbEventStore::Web::View.new("list", assigns)
  end

  # --- helpers ---

  def test_h_escapes_html
    assert_equal "&lt;b&gt;&amp;", view.h("<b>&")
  end

  def test_h_coerces_nil_to_empty
    assert_equal "", view.h(nil)
  end

  def test_short_truncates_to_eight
    assert_equal "abcdefgh", view.short("abcdefghijkl")
  end

  def test_short_handles_nil
    assert_equal "", view.short(nil)
  end

  def test_format_time
    assert_equal "1970-01-01 00:00:00", view.format_time(Time.at(0).utc)
  end

  def test_pretty_json
    assert_equal "{\n  \"a\": 1\n}", view.pretty_json({ a: 1 })
  end

  # --- link helpers (mount-aware) ---

  def params(pairs = [])
    DcbEventStore::Web::ListParams.new(pairs)
  end

  def test_base_defaults_to_empty
    assert_equal "", view.base
  end

  def test_base_from_assign
    assert_equal "/dcb", view(base: "/dcb").base
  end

  def test_root_url_uses_base
    assert_equal "/dcb/", view(base: "/dcb").root_url
  end

  def test_event_url_uses_base
    assert_equal "/dcb/events/7", view(base: "/dcb").event_url(7)
  end

  def test_filter_url_no_filter_is_root
    assert_equal "/", view(base: "").filter_url(type: "", tags: [])
  end

  def test_filter_url_with_type_and_tags
    link = view(base: "").filter_url(type: "A", tags: ["order:1", "customer:2"])
    assert_equal "/?type=A&tag=order%3A1&tag=customer%3A2", link
  end

  def test_filter_url_omits_default_per_page
    assert_equal "/?type=A", view(base: "").filter_url(type: "A", tags: [], per_page: 50)
  end

  def test_filter_url_keeps_non_default_per_page
    assert_equal "/?type=A&per_page=25", view(base: "").filter_url(type: "A", tags: [], per_page: 25)
  end

  def test_filter_url_omits_first_page
    assert_equal "/?type=A", view(base: "").filter_url(type: "A", tags: [], page: 1)
  end

  def test_filter_url_includes_later_page
    assert_equal "/?type=A&page=2", view(base: "").filter_url(type: "A", tags: [], page: 2)
  end

  def test_add_tag_url_appends_to_current_tags
    v = view(base: "", params: params([["tag", "order:1"]]))
    assert_equal "/?tag=order%3A1&tag=customer%3A2", v.add_tag_url("customer:2")
  end

  def test_add_tag_url_does_not_duplicate
    v = view(base: "", params: params([["tag", "order:1"]]))
    assert_equal "/?tag=order%3A1", v.add_tag_url("order:1")
  end

  def test_remove_tag_url_drops_the_tag
    v = view(base: "", params: params([%w[tag a], %w[tag b]]))
    assert_equal "/?tag=a", v.remove_tag_url("b")
  end

  def test_page_url_preserves_filter
    v = view(base: "", params: params([%w[type A], %w[tag x]]))
    assert_equal "/?type=A&tag=x&page=2", v.page_url(2)
  end

  def test_tag_url_is_fresh_single_tag_filter
    assert_equal "/?tag=order%3A1", view(base: "").tag_url("order:1")
  end

  # --- assigns as methods ---

  def test_assigns_exposed_as_methods
    assert_equal 42, view(total: 42).total
  end

  def test_responds_to_assigned_names
    assert_respond_to view(total: 42), :total
  end

  def test_unknown_method_raises
    assert_raises(NoMethodError) { view.nope }
  end

  # --- render ---

  def test_render_wraps_template_in_layout
    html = DcbEventStore::Web::View.render("not_found")
    assert_includes html, "<!DOCTYPE html>"
    assert_includes html, "Not found"
  end

  # --- namespaces ---

  def test_links_carry_the_namespace
    v = view(namespace: "billing")
    assert_equal "/?ns=billing", v.root_url
    assert_equal "/events/7?ns=billing", v.event_url(7)
    assert_equal "/?ns=billing&type=A", v.filter_url(type: "A", tags: [])
  end

  def test_default_namespace_adds_no_param
    assert_equal "/events/7", view(namespace: nil).event_url(7)
  end

  def test_namespaces_default_to_the_default_only
    assert_equal [nil], view.namespaces
    assert_nil view.namespace
  end

  def test_namespace_label
    assert_equal "default", view.namespace_label(nil)
    assert_equal "billing", view.namespace_label("billing")
  end

  # --- snapshot links ---

  def test_snapshots_url
    assert_equal "/dcb/snapshots", view(base: "/dcb").snapshots_url
  end

  def test_snapshots_url_with_filter_and_paging
    assert_equal "/snapshots?q=a%2Fv1&per_page=10&page=2",
                 view.snapshots_url(match: "a/v1", page: 2, per_page: 10)
  end

  def test_snapshots_url_omits_default_per_page_and_first_page
    assert_equal "/snapshots", view.snapshots_url(match: "", page: 1, per_page: 50)
  end

  def test_snapshots_url_in_namespace
    assert_equal "/snapshots?ns=billing&q=x", view(namespace: "billing").snapshots_url(match: "x")
  end

  def test_snapshot_url_encodes_the_key
    assert_equal "/snapshot?key=a%2Fv1%2Fq", view.snapshot_url("a/v1/q")
    assert_equal "/snapshot?ns=billing&key=k", view(namespace: "billing").snapshot_url("k")
  end

  def test_snapshot_page_url_keeps_the_filter
    v = view(params: params([%w[q a], %w[per_page 10]]))
    assert_equal "/snapshots?q=a&per_page=10&page=3", v.snapshot_page_url(3)
  end

  def test_current_nav
    assert_equal :events, DcbEventStore::Web::View.new("list", {}).current_nav
    assert_equal :events, DcbEventStore::Web::View.new("event", {}).current_nav
    assert_equal :snapshots, DcbEventStore::Web::View.new("snapshots", {}).current_nav
    assert_equal :snapshots, DcbEventStore::Web::View.new("snapshot", {}).current_nav
  end
end
