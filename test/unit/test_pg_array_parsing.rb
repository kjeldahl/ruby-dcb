require_relative "../test_helper"
require_relative "../support/database"

class TestPgArrayParsing < Minitest::Test
  cover "DcbEventStore::Store#parse_pg_array"
  cover "DcbEventStore::Store#to_pg_array"

  include DatabaseHelper

  def setup
    setup_db
  end

  def teardown
    teardown_db
  end

  # --- parse_pg_array tests ---

  def test_parse_pg_array_nil
    assert_equal [], @store.send(:parse_pg_array, nil)
  end

  def test_parse_pg_array_empty_braces
    assert_equal [], @store.send(:parse_pg_array, "{}")
  end

  def test_parse_pg_array_single_element
    assert_equal ["tag1"], @store.send(:parse_pg_array, "{tag1}")
    assert_equal ["tag1"], @store.send(:parse_pg_array, '{"tag1"}')
  end

  def test_parse_pg_array_multiple_unquoted_elements
    # PostgreSQL omits quotes for simple elements: this is the common case.
    assert_equal %w[tag1 tag2 tag3], @store.send(:parse_pg_array, "{tag1,tag2,tag3}")
  end

  def test_parse_pg_array_multiple_quoted_elements
    assert_equal %w[tag1 tag2 tag3], @store.send(:parse_pg_array, '{"tag1","tag2","tag3"}')
  end

  def test_parse_pg_array_with_empty_string
    assert_equal ["", "tag1"], @store.send(:parse_pg_array, '{"",tag1}')
  end

  def test_parse_pg_array_with_escaped_quote
    # PostgreSQL escapes embedded quotes with a backslash (not by doubling).
    assert_equal ['a"b'], @store.send(:parse_pg_array, '{"a\"b"}')
  end

  def test_parse_pg_array_with_embedded_comma
    assert_equal ["tag,with,commas"], @store.send(:parse_pg_array, '{"tag,with,commas"}')
  end

  def test_parse_pg_array_with_unicode
    assert_equal ["tag_with_émojis_🎉"], @store.send(:parse_pg_array, "{tag_with_émojis_🎉}")
  end

  # --- to_pg_array tests ---

  def test_to_pg_array_empty
    assert_equal "{}", @store.send(:to_pg_array, [])
  end

  def test_to_pg_array_single_element
    assert_equal "{tag1}", @store.send(:to_pg_array, ["tag1"])
  end

  def test_to_pg_array_multiple_elements
    assert_equal "{tag1,tag2,tag3}", @store.send(:to_pg_array, %w[tag1 tag2 tag3])
  end

  def test_to_pg_array_quotes_special_characters
    assert_equal '{"tag,with,commas"}', @store.send(:to_pg_array, ["tag,with,commas"])
    assert_equal '{"a\"b"}', @store.send(:to_pg_array, ['a"b'])
  end

  def test_to_pg_array_coerces_to_strings
    assert_equal "{1,2}", @store.send(:to_pg_array, [1, 2])
  end

  # --- Roundtrip tests (through a real text[] column) ---

  def roundtrip(arr)
    literal = @store.send(:to_pg_array, arr)
    stored = @conn.exec_params("SELECT $1::text[] AS a", [literal])[0]["a"]
    @store.send(:parse_pg_array, stored)
  end

  def test_roundtrip_simple
    original = ["tag1", "tag:with:colons", "tag-with-hyphens"]
    assert_equal original, roundtrip(original)
  end

  def test_roundtrip_special_characters
    original = ['tag"with"quotes', "tag,with,commas", "tag{with}braces", "tag with spaces"]
    assert_equal original, roundtrip(original)
  end

  def test_roundtrip_empty_strings_and_unicode
    original = ["", "tag_with_émojis_🎉", ""]
    assert_equal original, roundtrip(original)
  end
end
