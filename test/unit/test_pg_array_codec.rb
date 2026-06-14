require_relative "../test_helper"
require "pg"

class TestPgArrayCodec < Minitest::Test
  cover "DcbEventStore::PgArrayCodec*"

  def setup
    @codec = DcbEventStore::PgArrayCodec.new
  end

  # --- parse ---

  def test_parse_nil
    assert_equal [], @codec.parse(nil)
  end

  def test_parse_empty_braces
    assert_equal [], @codec.parse("{}")
  end

  def test_parse_single_element
    assert_equal ["tag1"], @codec.parse("{tag1}")
    assert_equal ["tag1"], @codec.parse('{"tag1"}')
  end

  def test_parse_multiple_unquoted_elements
    # PostgreSQL omits quotes for simple elements: this is the common case.
    assert_equal %w[tag1 tag2 tag3], @codec.parse("{tag1,tag2,tag3}")
  end

  def test_parse_multiple_quoted_elements
    assert_equal %w[tag1 tag2 tag3], @codec.parse('{"tag1","tag2","tag3"}')
  end

  def test_parse_with_empty_string
    assert_equal ["", "tag1"], @codec.parse('{"",tag1}')
  end

  def test_parse_with_escaped_quote
    # PostgreSQL escapes embedded quotes with a backslash (not by doubling).
    assert_equal ['a"b'], @codec.parse('{"a\"b"}')
  end

  def test_parse_with_embedded_comma
    assert_equal ["tag,with,commas"], @codec.parse('{"tag,with,commas"}')
  end

  def test_parse_with_unicode
    assert_equal ["tag_with_émojis_🎉"], @codec.parse("{tag_with_émojis_🎉}")
  end

  # --- encode ---

  def test_encode_empty
    assert_equal "{}", @codec.encode([])
  end

  def test_encode_single_element
    assert_equal "{tag1}", @codec.encode(["tag1"])
  end

  def test_encode_multiple_elements
    assert_equal "{tag1,tag2,tag3}", @codec.encode(%w[tag1 tag2 tag3])
  end

  def test_encode_quotes_special_characters
    assert_equal '{"tag,with,commas"}', @codec.encode(["tag,with,commas"])
    assert_equal '{"a\"b"}', @codec.encode(['a"b'])
  end

  def test_encode_coerces_to_strings
    assert_equal "{1,2}", @codec.encode([1, 2])
  end

  def test_encode_coerces_nil_to_empty_string
    # nil.to_s is "", distinct from the encoder's own nil handling ({NULL}).
    assert_equal '{""}', @codec.encode([nil])
  end
end
