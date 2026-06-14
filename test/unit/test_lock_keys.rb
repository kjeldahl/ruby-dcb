require_relative "../test_helper"
require "zlib"

class TestLockKeys < Minitest::Test
  cover "DcbEventStore::Store::LockKeys*"

  def condition(items)
    query = DcbEventStore::Query.new(items)
    DcbEventStore::AppendCondition.new(fail_if_events_match: query)
  end

  def item(event_types: [], tags: [])
    DcbEventStore::QueryItem.new(event_types: event_types, tags: tags)
  end

  def test_nil_condition_uses_global_key
    assert_equal [0], DcbEventStore::Store::LockKeys.for(nil)
  end

  def test_condition_without_tags_uses_global_key
    cond = condition([item(event_types: ["A"])])
    assert_equal [0], DcbEventStore::Store::LockKeys.for(cond)
  end

  def test_condition_with_single_tag
    cond = condition([item(tags: ["t1"])])
    assert_equal [Zlib.crc32("t1")], DcbEventStore::Store::LockKeys.for(cond)
  end

  def test_keys_are_sorted
    # "b" hashes lower than "a", so an unsorted result would be in input order.
    keys = DcbEventStore::Store::LockKeys.for(condition([item(tags: %w[a b])]))
    assert_equal keys.sort, keys
    assert_equal [Zlib.crc32("a"), Zlib.crc32("b")].sort, keys
  end

  def test_duplicate_tags_collapse_to_one_key
    cond = condition([item(tags: ["t1"]), item(tags: ["t1"])])
    assert_equal [Zlib.crc32("t1")], DcbEventStore::Store::LockKeys.for(cond)
  end

  def test_tags_from_multiple_items_are_combined
    cond = condition([item(tags: ["t1"]), item(tags: ["t2"])])
    assert_equal [Zlib.crc32("t1"), Zlib.crc32("t2")].sort,
                 DcbEventStore::Store::LockKeys.for(cond)
  end
end
