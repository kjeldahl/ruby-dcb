require_relative "../test_helper"
require_relative "../support/database"

# Verifies PgArrayCodec round-trips through a real PostgreSQL text[] column:
# values it encodes are parsed back unchanged after Postgres has normalized the
# literal. Complements the pure encode/decode assertions in test_pg_array_codec.
class TestPgArrayRoundtrip < Minitest::Test
  include DatabaseHelper

  def setup
    setup_db
    @codec = DcbEventStore::PgArrayCodec.new
  end

  def teardown
    teardown_db
  end

  def roundtrip(arr)
    literal = @codec.encode(arr)
    stored = @conn.exec_params("SELECT $1::text[] AS a", [literal])[0]["a"]
    @codec.parse(stored)
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
