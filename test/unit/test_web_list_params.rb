require_relative "../test_helper"
require "dcb_event_store/web"

class TestWebListParams < Minitest::Test
  cover "DcbEventStore::Web::ListParams*"

  # ListParams takes decoded query pairs (Array of [key, value]), so repeated
  # "tag" params accumulate. A Hash is accepted too (single-valued convenience).
  def params(pairs = [])
    DcbEventStore::Web::ListParams.new(pairs)
  end

  # --- per_page ---

  def test_default_per_page
    assert_equal 50, params.per_page
  end

  def test_per_page_from_param
    assert_equal 10, params([%w[per_page 10]]).per_page
  end

  def test_per_page_clamped_to_max
    assert_equal 200, params([%w[per_page 9999]]).per_page
  end

  def test_zero_per_page_uses_default
    assert_equal 50, params([%w[per_page 0]]).per_page
  end

  def test_negative_per_page_uses_default
    assert_equal 50, params([["per_page", "-5"]]).per_page
  end

  def test_per_page_at_max_is_kept
    assert_equal 200, params([%w[per_page 200]]).per_page
  end

  # --- page ---

  def test_default_page
    assert_equal 1, params.page
  end

  def test_page_from_param
    assert_equal 4, params([%w[page 4]]).page
  end

  def test_page_below_one_floored
    assert_equal 1, params([%w[page 0]]).page
  end

  # --- offset ---

  def test_default_offset_zero
    assert_equal 0, params.offset
  end

  def test_offset_is_page_minus_one_times_per_page
    assert_equal 20, params([%w[page 3], %w[per_page 10]]).offset
  end

  # --- selected_type ---

  def test_selected_type_default_empty
    assert_equal "", params.selected_type
  end

  def test_selected_type_value
    assert_equal "OrderPlaced", params([%w[type OrderPlaced]]).selected_type
  end

  def test_last_type_wins
    assert_equal "B", params([%w[type A], %w[type B]]).selected_type
  end

  # --- tags (multi) ---

  def test_tags_default_empty
    assert_empty params.tags
  end

  def test_single_tag
    assert_equal ["order:1"], params([["tag", "order:1"]]).tags
  end

  def test_multiple_tags_accumulate_in_order
    assert_equal %w[a b], params([%w[tag a], %w[tag b]]).tags
  end

  def test_duplicate_tags_deduped
    assert_equal ["a"], params([%w[tag a], %w[tag a]]).tags
  end

  def test_empty_tags_ignored
    assert_equal ["a"], params([["tag", ""], ["tag", "a"]]).tags
  end

  # --- query ---

  def test_no_filter_matches_all
    assert params.query.match_all?
  end

  def test_blank_filters_match_all
    assert params([["type", ""], ["tag", ""]]).query.match_all?
  end

  def test_type_filter
    item = params([%w[type A]]).query.items.first
    assert_equal ["A"], item.event_types
    assert_empty item.tags
  end

  def test_tag_filter
    item = params([["tag", "order:1"]]).query.items.first
    assert_equal ["order:1"], item.tags
    assert_empty item.event_types
  end

  def test_multiple_tags_and_together_in_one_item
    item = params([["tag", "order:1"], ["tag", "customer:2"]]).query.items.first
    assert_equal ["order:1", "customer:2"], item.tags
  end

  def test_type_and_tag_filter
    item = params([["type", "A"], ["tag", "order:1"]]).query.items.first
    assert_equal ["A"], item.event_types
    assert_equal ["order:1"], item.tags
  end
end
