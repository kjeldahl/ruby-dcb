require_relative "../test_helper"

# ReadOptions: the direction, bound and limit of a read, validated once for
# every store, and the paging arithmetic the SQL stores' keyset reads use.
class TestReadOptions < Minitest::Test
  cover "DcbEventStore::ReadOptions*"

  ReadOptions = DcbEventStore::ReadOptions

  def test_defaults_to_a_forward_read_of_everything
    options = ReadOptions.new

    assert_nil options.after
    assert_nil options.before
    assert_equal false, options.backwards
    assert_nil options.limit
  end

  def test_takes_after_forwards_and_before_backwards
    assert_equal 5, ReadOptions.new(after: 5).after
    assert_equal 5, ReadOptions.new(before: 5, backwards: true).before
  end

  def test_rejects_after_on_a_backwards_read
    error = assert_raises(ArgumentError) { ReadOptions.new(after: 5, backwards: true) }
    assert_equal "after: reads forwards; a backwards read takes before:", error.message
  end

  def test_rejects_before_on_a_forward_read
    error = assert_raises(ArgumentError) { ReadOptions.new(before: 5) }
    assert_equal "before: bounds a backwards read; pass backwards: true", error.message
  end

  def test_rejects_a_backwards_flag_that_is_not_a_boolean
    [nil, 1, "true"].each do |flag|
      error = assert_raises(ArgumentError) { ReadOptions.new(backwards: flag) }
      assert_equal "backwards must be true or false, got #{flag.inspect}", error.message
    end
  end

  def test_rejects_a_limit_that_is_not_a_positive_integer
    [0, -1, 1.0, "1"].each do |limit|
      error = assert_raises(ArgumentError) { ReadOptions.new(limit: limit) }
      assert_equal "limit must be a positive Integer, got #{limit.inspect}", error.message
    end
    assert_equal 1, ReadOptions.new(limit: 1).limit
  end

  def test_order_is_the_sql_direction
    assert_equal :asc, ReadOptions.new.order
    assert_equal :desc, ReadOptions.new(backwards: true).order
  end

  # --- page_size ---

  def test_page_size_is_the_batch_size_without_a_limit
    assert_equal 1000, ReadOptions.new.page_size(1000)
  end

  def test_page_size_is_the_smaller_of_limit_and_batch_size
    assert_equal 3, ReadOptions.new(limit: 3).page_size(1000)
    assert_equal 1000, ReadOptions.new(limit: 1001).page_size(1000)
  end

  # --- after_page ---

  def test_after_page_moves_a_forward_read_past_the_page
    assert_equal ReadOptions.new(after: 42), ReadOptions.new(after: 2).after_page(42, 40)
  end

  def test_after_page_moves_a_backwards_read_before_the_page
    assert_equal ReadOptions.new(before: 7, backwards: true),
                 ReadOptions.new(backwards: true).after_page(7, 3)
  end

  def test_after_page_reduces_the_limit_by_the_page
    assert_equal ReadOptions.new(after: 9, limit: 2), ReadOptions.new(limit: 5).after_page(9, 3)
    assert_equal ReadOptions.new(before: 4, backwards: true, limit: 1),
                 ReadOptions.new(backwards: true, limit: 4).after_page(4, 3)
  end

  def test_after_page_is_nil_once_the_limit_is_used_up
    assert_nil ReadOptions.new(limit: 3).after_page(9, 3)
  end
end
