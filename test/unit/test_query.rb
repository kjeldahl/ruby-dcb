require_relative "../test_helper"

class TestQuery < Minitest::Test
  cover "DcbEventStore::Query*"
  cover "DcbEventStore::QueryItem*"

  def test_query_item_creation
    qi = DcbEventStore::QueryItem.new(event_types: %w[A B], tags: ["t:1"])
    assert_equal %w[A B], qi.event_types
    assert_equal ["t:1"], qi.tags
  end

  def test_query_item_coerces_to_strings
    qi = DcbEventStore::QueryItem.new(event_types: [:A], tags: [:t])
    assert_equal ["A"], qi.event_types
    assert_equal ["t"], qi.tags
  end

  def test_query_item_defaults_tags_empty
    qi = DcbEventStore::QueryItem.new(event_types: ["A"])
    assert_equal [], qi.tags
  end

  def test_query_stores_items
    items = [DcbEventStore::QueryItem.new(event_types: ["A"])]
    q = DcbEventStore::Query.new(items)
    assert_equal items, q.items
  end

  def test_query_items_frozen
    q = DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: ["A"])])
    assert q.items.frozen?
  end

  def test_query_coerces_single_item_to_array
    qi = DcbEventStore::QueryItem.new(event_types: ["A"])
    q = DcbEventStore::Query.new(qi)
    assert_equal [qi], q.items
  end

  def test_query_all_is_match_all
    assert DcbEventStore::Query.all.match_all?
  end

  def test_regular_query_not_match_all
    q = DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: ["A"])])
    refute q.match_all?
  end

  def test_equal_queries
    items = [DcbEventStore::QueryItem.new(event_types: ["A"], tags: ["t:1"])]
    assert_equal DcbEventStore::Query.new(items), DcbEventStore::Query.new(items)
  end

  def test_different_queries_not_equal
    a = DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: ["A"])])
    b = DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: ["B"])])
    refute_equal a, b
  end

  def test_query_not_equal_to_non_query
    q = DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: ["A"])])
    refute_equal q, "not a query"
  end

  def test_query_item_to_s_types_only
    qi = DcbEventStore::QueryItem.new(event_types: %w[A B])
    assert_equal "A,B", qi.to_s
  end

  def test_query_item_to_s_types_and_tags
    qi = DcbEventStore::QueryItem.new(event_types: %w[A B], tags: ["t:1"])
    assert_equal "A,B{t:1}", qi.to_s
  end

  def test_query_item_to_s_tags_only
    qi = DcbEventStore::QueryItem.new(event_types: [], tags: ["t:1", "t:2"])
    assert_equal "{t:1,t:2}", qi.to_s
  end

  def test_query_item_to_s_empty_is_any
    qi = DcbEventStore::QueryItem.new(event_types: [], tags: [])
    assert_equal "any", qi.to_s
  end

  def test_query_item_inspect_matches_to_s
    qi = DcbEventStore::QueryItem.new(event_types: ["A"], tags: ["t:1"])
    assert_equal qi.to_s, qi.inspect
  end

  def test_query_all_to_s
    assert_equal "Query.all", DcbEventStore::Query.all.to_s
  end

  def test_query_to_s_joins_items_with_pipe
    q = DcbEventStore::Query.new([
                                   DcbEventStore::QueryItem.new(event_types: %w[A B], tags: ["t:1"]),
                                   DcbEventStore::QueryItem.new(event_types: ["C"])
                                 ])
    assert_equal "Query[A,B{t:1}|C]", q.to_s
  end

  def test_query_inspect_matches_to_s
    q = DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: ["A"])])
    assert_equal q.to_s, q.inspect
  end

  def test_append_condition_defaults_after_nil
    ac = DcbEventStore::AppendCondition.new(fail_if_events_match: DcbEventStore::Query.all)
    assert_nil ac.after
  end

  def test_append_condition_with_after
    ac = DcbEventStore::AppendCondition.new(
      fail_if_events_match: DcbEventStore::Query.all,
      after: 42
    )
    assert_equal 42, ac.after
  end
end

# Query#fingerprint is the cache identity snapshots key on; unlike #to_s it
# must tell apart every pair of different queries.
class TestQueryFingerprint < Minitest::Test
  cover "DcbEventStore::Query*"

  def item(event_types: [], tags: []) = DcbEventStore::QueryItem.new(event_types: event_types, tags: tags)

  def test_renders_items_as_json_pairs_of_types_and_tags
    query = DcbEventStore::Query.new([item(event_types: %w[A B], tags: ["t:1"]), item(tags: ["t:2"])])
    assert_equal '[[["A","B"],["t:1"]],[[],["t:2"]]]', query.fingerprint
  end

  def test_unbounded_query_is_an_empty_list
    assert_equal "[]", DcbEventStore::Query.all.fingerprint
  end

  def test_tags_that_render_alike_in_to_s_get_different_fingerprints
    two_tags = DcbEventStore::Query.new([item(event_types: ["E"], tags: %w[a b])])
    one_tag = DcbEventStore::Query.new([item(event_types: ["E"], tags: ["a,b"])])

    assert_equal two_tags.to_s, one_tag.to_s
    refute_equal two_tags.fingerprint, one_tag.fingerprint
  end

  def test_equal_queries_share_a_fingerprint
    a = DcbEventStore::Query.new([item(event_types: [:A], tags: [:t])])
    b = DcbEventStore::Query.new([item(event_types: ["A"], tags: ["t"])])
    assert_equal a.fingerprint, b.fingerprint
  end
end
