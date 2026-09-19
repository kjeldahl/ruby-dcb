require_relative "../test_helper"

# Regression tests for a cache-key ambiguity: MaterializedStreams and
# Snapshot both identify a query, and both used to do it with Query#to_s.
# That rendering was built for logs and joins types and tags with "," without
# escaping, so distinct queries rendered identically -- a single tag "a,b"
# renders exactly like the two tags "a" and "b" ("Query[E{a,b}]"). Whichever
# query was seen second was then served the other one's materialized stream,
# or the other one's snapshot, and returned events or a state that belong to
# a different entity.
#
# Both now key off Query#fingerprint, which is unambiguous. These tests pin
# that: the pair below still renders alike, and must still be kept apart.
class TestQueryKeyCollisions < Minitest::Test
  cover "DcbEventStore::Query*"
  cover "DcbEventStore::Snapshot*"
  cover "DcbEventStore::MaterializedStreams*"

  def setup
    @store = DcbEventStore::InMemoryStore.new
    # Event 1 carries two tags, event 2 carries one tag that contains a comma.
    @store.append([DcbEventStore::Event.new(type: "E", tags: %w[a b])])
    @store.append([DcbEventStore::Event.new(type: "E", tags: ["a,b"])])

    @two_tags = DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: ["E"], tags: %w[a b])])
    @one_tag = DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: ["E"], tags: ["a,b"])])
  end

  # The premise: these two really do render alike, and the store really does
  # keep them apart. Only a key derived from #to_s would confuse them.
  def test_the_two_queries_render_alike_but_select_different_events
    assert_equal @two_tags.to_s, @one_tag.to_s
    refute_equal @two_tags.fingerprint, @one_tag.fingerprint

    assert_equal [1], @store.read(@two_tags).map(&:sequence_position)
    assert_equal [2], @store.read(@one_tag).map(&:sequence_position)
  end

  def test_materialized_streams_do_not_confuse_two_queries_that_render_alike
    streams = DcbEventStore::MaterializedStreams.new(@store)

    assert_equal [1], streams.read(@two_tags).map(&:sequence_position)
    assert_equal [2], streams.read(@one_tag).map(&:sequence_position),
                 "the stream cached for #{@two_tags} was served for a different query"
    assert_equal 2, streams.size
  end

  # Same for the types side of an item: one type "A,B" against the two types
  # "A" and "B".
  def test_materialized_streams_do_not_confuse_two_type_lists_that_render_alike
    @store.append([DcbEventStore::Event.new(type: "A,B", tags: ["t"])])
    @store.append([DcbEventStore::Event.new(type: "A", tags: ["t"])])
    one_type = DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: ["A,B"], tags: ["t"])])
    two_types = DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: %w[A B], tags: ["t"])])
    streams = DcbEventStore::MaterializedStreams.new(@store)

    assert_equal one_type.to_s, two_types.to_s
    assert_equal [3], streams.read(one_type).map(&:sequence_position)
    assert_equal [4], streams.read(two_types).map(&:sequence_position)
  end

  def test_snapshot_keys_do_not_confuse_two_queries_that_render_alike
    snapshots = DcbEventStore::Snapshots::InMemorySnapshotStore.new
    config = DcbEventStore::Snapshot.new(name: "count")
    projection = lambda do |query|
      DcbEventStore::Projection.new(initial_state: 0, handlers: { "E" => ->(s, _e) { s + 1 } },
                                    query: query, snapshot: config)
    end

    refute_equal config.key(@two_tags), config.key(@one_tag),
                 "two queries selecting different events share one snapshot key"

    DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, p: projection.call(@two_tags))
    snapshotted = DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, p: projection.call(@one_tag))

    assert_equal 1, snapshotted.states[:p]
    assert_equal DcbEventStore::DecisionModel.build(@store, p: projection.call(@one_tag)).states[:p],
                 snapshotted.states[:p]
  end
end
