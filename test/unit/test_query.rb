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
