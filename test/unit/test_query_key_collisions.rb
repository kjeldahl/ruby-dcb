require_relative "../test_helper"

# Regression tests for a cache-key ambiguity: Snapshot identifies a query,
# and used to do it with Query#to_s. That rendering was built for logs and
# joins types and tags with "," without escaping, so distinct queries rendered
# identically -- a single tag "a,b" renders exactly like the two tags "a" and
# "b" ("Query[E{a,b}]"). Whichever query was seen second was then served the
# other one's snapshot, and returned a state that belongs to a different
# entity.
#
# Keys now come from Query#fingerprint, which is unambiguous. These tests pin
# that: the pair below still renders alike, and must still be kept apart.
class TestQueryKeyCollisions < Minitest::Test
  cover "DcbEventStore::Query*"
  cover "DcbEventStore::Snapshot*"

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
