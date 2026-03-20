require_relative "../test_helper"

class TestQuery < Minitest::Test
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

  def test_query_all_is_match_all
    assert DcbEventStore::Query.all.match_all?
  end

  def test_regular_query_not_match_all
    q = DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: ["A"])])
    refute q.match_all?
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
