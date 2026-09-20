require_relative "../test_helper"
require "zlib"

class TestLockKeys < Minitest::Test
  cover "DcbEventStore::PostgresStore::LockKeys*"

  LockKeys = DcbEventStore::PostgresStore::LockKeys

  def condition(items)
    query = items.is_a?(DcbEventStore::Query) ? items : DcbEventStore::Query.new(items)
    DcbEventStore::AppendCondition.new(fail_if_events_match: query)
  end

  def item(event_types: [], tags: [])
    DcbEventStore::QueryItem.new(event_types: event_types, tags: tags)
  end

  def event(tags)
    DcbEventStore::Event.new(type: "A", tags: tags)
  end

  def locks(events, cond)
    LockKeys.for(events, cond)
  end

  def crc(*tags)
    tags.map { |tag| Zlib.crc32(tag) }.sort
  end

  def test_unconditional_untagged_append_takes_only_the_global_key_shared
    assert_equal LockKeys::Locks.new(global: :shared, tags: []), locks([event([])], nil)
  end

  def test_unconditional_append_locks_the_tags_its_events_carry
    assert_equal LockKeys::Locks.new(global: :shared, tags: crc("t1", "t2")),
                 locks([event(["t1"]), event(["t2"])], nil)
  end

  def test_condition_without_tags_takes_the_global_key_exclusively
    cond = condition([item(event_types: ["A"])])
    assert_equal LockKeys::Locks.new(global: :exclusive, tags: []), locks([event([])], cond)
  end

  def test_match_all_condition_takes_the_global_key_exclusively
    assert_equal LockKeys::Locks.new(global: :exclusive, tags: []),
                 locks([event([])], condition(DcbEventStore::Query.all))
  end

  def test_untagged_condition_item_is_exclusive_even_next_to_tagged_items
    cond = condition([item(tags: ["t1"]), item(event_types: ["A"])])
    assert_equal LockKeys::Locks.new(global: :exclusive, tags: crc("t1")), locks([], cond)
  end

  def test_condition_with_single_tag
    cond = condition([item(tags: ["t1"])])
    assert_equal LockKeys::Locks.new(global: :shared, tags: crc("t1")), locks([], cond)
  end

  def test_event_and_condition_tags_are_combined
    cond = condition([item(tags: ["t1"])])
    assert_equal LockKeys::Locks.new(global: :shared, tags: crc("t1", "t2")), locks([event(["t2"])], cond)
  end

  def test_keys_are_sorted
    # "b" hashes lower than "a", so an unsorted result would be in input order.
    keys = locks([], condition([item(tags: %w[a b])])).tags
    assert_equal keys.sort, keys
    assert_equal crc("a", "b"), keys
  end

  def test_duplicate_tags_collapse_to_one_key
    cond = condition([item(tags: ["t1"]), item(tags: ["t1"])])
    assert_equal crc("t1"), locks([event(["t1"])], cond).tags
  end

  def test_tags_from_multiple_items_are_combined
    cond = condition([item(tags: ["t1"]), item(tags: ["t2"])])
    assert_equal crc("t1", "t2"), locks([], cond).tags
  end

  # Two appends each taking key 0 shared and then exclusive (a tag hashing to
  # 0) would deadlock, so such a tag is folded into an exclusive global lock.
  def test_tag_hashing_to_the_global_key_makes_it_exclusive
    Zlib.stub(:crc32, ->(tag) { tag == "zero" ? LockKeys::APPEND_LOCK_KEY : 7 }) do
      assert_equal LockKeys::Locks.new(global: :exclusive, tags: [7]), locks([event(%w[zero other])], nil)
    end
  end
end
