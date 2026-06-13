require "test_helper"

class TestPgArrayParsing < Minitest::Test
  cover "DcbEventStore::Store#parse_pg_array"
  cover "DcbEventStore::Store#to_pg_array"

  def setup
    @store = DcbEventStore::Store.new(PG.connect(dbname: "dcb_event_store_test"))
  end

  def teardown
    @store.instance_variable_get(:@conn).close
  end

  # --- parse_pg_array tests ---

  def test_parse_pg_array_nil
    assert_equal [], @store.send(:parse_pg_array, nil)
  end

  def test_parse_pg_array_empty_braces
    assert_equal [], @store.send(:parse_pg_array, "{}")
  end

  def test_parse_pg_array_empty_with_whitespace
    assert_equal [], @store.send(:parse_pg_array, "{ }")
    assert_equal [], @store.send(:parse_pg_array, "  { }  ")
  end

  def test_parse_pg_array_single_element
    assert_equal ["tag1"], @store.send(:parse_pg_array, '{"tag1"}')
  end

  def test_parse_pg_array_multiple_elements
    assert_equal ["tag1", "tag2", "tag3"], @store.send(:parse_pg_array, '{"tag1","tag2","tag3"}')
  end

  def test_parse_pg_array_with_whitespace
    # PostgreSQL may include whitespace after commas
    assert_equal ["tag1", "tag2"], @store.send(:parse_pg_array, '{"tag1", "tag2"}')
    assert_equal ["tag1", "tag2"], @store.send(:parse_pg_array, '{"tag1","tag2" }')
    assert_equal ["tag1", "tag2"], @store.send(:parse_pg_array, '{ "tag1","tag2" }')
    assert_equal ["tag1", "tag2"], @store.send(:parse_pg_array, '{ "tag1" , "tag2" }')
  end

  def test_parse_pg_array_with_empty_string
    # PostgreSQL can have empty strings in arrays
    assert_equal ["", "tag1"], @store.send(:parse_pg_array, '{"","tag1"}')
  end

  def test_parse_pg_array_with_escaped_quotes
    # PostgreSQL escapes quotes as double quotes
    # In PG output: {"a""b"} means the string a"b
    assert_equal ["a\"b"], @store.send(:parse_pg_array, '{"a""b"}')
    assert_equal ["tag\"with\"quotes"], @store.send(:parse_pg_array, '{"tag""with""quotes"}')
  end

  def test_parse_pg_array_with_special_characters
    assert_equal ["tag:with:colons"], @store.send(:parse_pg_array, '{"tag:with:colons"}')
    assert_equal ["tag,with,commas"], @store.send(:parse_pg_array, '{"tag,with,commas"}')
    assert_equal ["tag{with}braces"], @store.send(:parse_pg_array, '{"tag{with}braces"}')
  end

  def test_parse_pg_array_with_unicode
    assert_equal ["tag_with_émojis_🎉"], @store.send(:parse_pg_array, '{"tag_with_émojis_🎉"}')
  end

  def test_parse_pg_array_with_backslashes
    # PostgreSQL doesn't use backslash escaping for quotes in text arrays
    # but we should handle it gracefully
    assert_equal ["tag\\with\\backslashes"], @store.send(:parse_pg_array, '{"tag\\with\\backslashes"}')
  end

  # --- to_pg_array tests ---

  def test_to_pg_array_empty
    assert_equal "{}", @store.send(:to_pg_array, [])
  end

  def test_to_pg_array_single_element
    assert_equal '{"tag1"}', @store.send(:to_pg_array, ["tag1"])
  end

  def test_to_pg_array_multiple_elements
    assert_equal '{"tag1","tag2","tag3"}', @store.send(:to_pg_array, ["tag1", "tag2", "tag3"])
  end

  def test_to_pg_array_with_quotes
    # Should properly escape quotes by doubling them
    result = @store.send(:to_pg_array, ["tag\"with\"quotes"])
    assert_equal '{"tag""with""quotes"}', result
  end

  def test_to_pg_array_with_special_characters
    assert_equal '{"tag:with:colons"}', @store.send(:to_pg_array, ["tag:with:colons"])
    assert_equal '{"tag,with,commas"}', @store.send(:to_pg_array, ["tag,with,commas"])
  end

  def test_to_pg_array_with_empty_string
    assert_equal '{"","tag1"}', @store.send(:to_pg_array, ["", "tag1"])
  end

  def test_to_pg_array_with_unicode
    assert_equal '{"tag_with_émojis_🎉"}', @store.send(:to_pg_array, ["tag_with_émojis_🎉"])
  end

  # --- Roundtrip tests ---

  def test_to_pg_array_and_parse_pg_array_roundtrip
    # Test that to_pg_array and parse_pg_array are inverses
    original = ["tag1", "tag:with:colons", "tag,with,commas"]
    pg_array = @store.send(:to_pg_array, original)
    parsed = @store.send(:parse_pg_array, pg_array)
    assert_equal original, parsed
  end

  def test_to_pg_array_and_parse_pg_array_roundtrip_with_quotes
    original = ["tag\"with\"quotes", "normal"]
    pg_array = @store.send(:to_pg_array, original)
    parsed = @store.send(:parse_pg_array, pg_array)
    assert_equal original, parsed
  end

  def test_to_pg_array_and_parse_pg_array_roundtrip_with_empty_string
    original = ["", "tag1", ""]
    pg_array = @store.send(:to_pg_array, original)
    parsed = @store.send(:parse_pg_array, pg_array)
    assert_equal original, parsed
  end

  def test_to_pg_array_and_parse_pg_array_roundtrip_with_unicode
    original = ["tag_with_émojis_🎉", "normal"]
    pg_array = @store.send(:to_pg_array, original)
    parsed = @store.send(:parse_pg_array, pg_array)
    assert_equal original, parsed
  end
end
