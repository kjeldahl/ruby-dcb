require_relative "../test_helper"
require_relative "../support/database"

# End-to-end coverage for tags containing PostgreSQL array metacharacters
# (commas, quotes, braces, backslashes, whitespace), empty strings, and
# Unicode. Exercises the full production path: Store#append encodes via
# to_pg_array into a real text[] column, and Store#read decodes it back via
# parse_pg_array. Also verifies tag containment queries (tags @> ...) still
# match when the tag needs quoting.
class TestSpecialCharTags < Minitest::Test
  cover "DcbEventStore::Store#append"
  cover "DcbEventStore::Store#read"

  include DatabaseHelper

  SPECIAL_TAGS = [
    'tag"with"quotes',
    "tag,with,commas",
    "tag{with}braces",
    'tag\\with\\backslash',
    "tag with spaces",
    "tag_with_émojis_🎉",
    ""
  ].freeze

  def setup
    setup_db
  end

  def teardown
    teardown_db
  end

  def test_append_then_read_preserves_special_char_tags
    @store.append([DcbEventStore::Event.new(type: "A", tags: SPECIAL_TAGS)])

    event = @store.read(DcbEventStore::Query.all).first
    assert_equal SPECIAL_TAGS, event.tags
  end

  def test_containment_query_matches_special_char_tag
    @store.append([DcbEventStore::Event.new(type: "A", tags: ["course:c1", "tag,with,commas"])])
    @store.append([DcbEventStore::Event.new(type: "A", tags: ["course:c2"])])

    query = DcbEventStore::Query.new([
                                       DcbEventStore::QueryItem.new(event_types: ["A"], tags: ["tag,with,commas"])
                                     ])
    events = @store.read(query).to_a

    assert_equal 1, events.size
    assert_includes events[0].tags, "tag,with,commas"
  end

  def test_containment_query_does_not_overmatch_on_quoted_tag
    @store.append([DcbEventStore::Event.new(type: "A", tags: ['tag"with"quotes'])])

    query = DcbEventStore::Query.new([
                                       DcbEventStore::QueryItem.new(event_types: ["A"], tags: ["tag"])
                                     ])
    assert_empty @store.read(query).to_a
  end
end
