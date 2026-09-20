require_relative "../test_helper"

# Behavioral unit tests for DecisionModel against InMemoryStore, so the
# pure filtering/partitioning logic is mutation-tested without a live
# database (end-to-end coverage lives in the shared DecisionModelContract).
class TestDecisionModelUnit < Minitest::Test
  cover "DcbEventStore::DecisionModel*"

  def setup
    @store = DcbEventStore::InMemoryStore.new
  end

  def projection(event_types:, tags:, handlers:)
    DcbEventStore::Projection.new(
      initial_state: 0,
      handlers: handlers,
      query: DcbEventStore::Query.new([
                                        DcbEventStore::QueryItem.new(event_types: event_types, tags: tags)
                                      ])
    )
  end

  def test_specific_event_types_exclude_other_types
    @store.append([
                    DcbEventStore::Event.new(type: "Wanted", tags: ["t:1"]),
                    DcbEventStore::Event.new(type: "Other", tags: ["t:1"])
                  ])

    proj = projection(event_types: ["Wanted"], tags: ["t:1"],
                      handlers: { "Wanted" => ->(s, _e) { s + 1 }, "Other" => ->(s, _e) { s + 100 } })

    result = DcbEventStore::DecisionModel.build(@store, p: proj)
    assert_equal 1, result.states[:p]
  end

  def test_empty_event_types_match_all_types
    @store.append([
                    DcbEventStore::Event.new(type: "A", tags: ["t:1"]),
                    DcbEventStore::Event.new(type: "B", tags: ["t:1"])
                  ])

    proj = projection(event_types: [], tags: ["t:1"],
                      handlers: { "A" => ->(s, _e) { s + 1 }, "B" => ->(s, _e) { s + 1 } })

    result = DcbEventStore::DecisionModel.build(@store, p: proj)
    assert_equal 2, result.states[:p]
  end

  def test_condition_after_is_highest_sequence_position
    appended = @store.append([
                               DcbEventStore::Event.new(type: "A", tags: ["t:1"]),
                               DcbEventStore::Event.new(type: "A", tags: ["t:1"])
                             ])

    proj = projection(event_types: ["A"], tags: ["t:1"], handlers: { "A" => ->(s, _e) { s + 1 } })
    result = DcbEventStore::DecisionModel.build(@store, p: proj)

    assert_equal appended.last.sequence_position, result.append_condition.after
  end

  def test_condition_after_is_nil_on_empty_store
    proj = projection(event_types: ["A"], tags: ["t:1"], handlers: { "A" => ->(s, _e) { s + 1 } })
    result = DcbEventStore::DecisionModel.build(@store, p: proj)

    assert_nil result.append_condition.after
  end

  # No projections: the union of no queries is Query.all, so the condition
  # guards the whole log and after is its last position.
  def test_without_projections_the_condition_guards_the_whole_log
    appended = @store.append([DcbEventStore::Event.new(type: "A"), DcbEventStore::Event.new(type: "B")])

    result = DcbEventStore::DecisionModel.build(@store)

    assert_empty result.states
    assert_equal DcbEventStore::Query.all, result.append_condition.fail_if_events_match
    assert_equal appended.last.sequence_position, result.append_condition.after
  end

  # Without a snapshot store the build does not consult the log head: the
  # condition stops at the last matching event, and an unrelated event
  # appended after it is not guarded (nor paid for with an extra query).
  def test_without_snapshots_after_is_the_last_matching_event_not_the_head
    matching = @store.append([DcbEventStore::Event.new(type: "A", tags: ["t:1"])]).last
    @store.append([DcbEventStore::Event.new(type: "Unrelated", tags: ["t:9"])])
    proj = projection(event_types: ["A"], tags: ["t:1"], handlers: { "A" => ->(s, _e) { s + 1 } })

    result = DcbEventStore::DecisionModel.build(@store, p: proj)

    assert_equal matching.sequence_position, result.append_condition.after
    refute_equal @store.last_position, result.append_condition.after
  end

  # No snapshot store, no head: the build never asks the store for its last
  # position (one query less), the single read is the whole coverage.
  def test_without_snapshots_the_head_is_not_consulted
    store = @store
    headless = Object.new
    headless.define_singleton_method(:read) { |query| store.read(query) }
    headless.define_singleton_method(:read_from) { |query, after:| store.read_from(query, after: after) }
    appended = @store.append([DcbEventStore::Event.new(type: "A", tags: ["t:1"])])
    proj = projection(event_types: ["A"], tags: ["t:1"], handlers: { "A" => ->(s, _e) { s + 1 } })

    result = DcbEventStore::DecisionModel.build(headless, p: proj)

    assert_equal 1, result.states[:p]
    assert_equal appended.last.sequence_position, result.append_condition.after
  end

  # The bound applies to the whole-log read of a build without projections
  # just the same.
  def test_without_projections_the_head_still_bounds_the_read
    store = @store
    stale = Object.new
    stale.define_singleton_method(:last_position) { 1 }
    stale.define_singleton_method(:read) { |query| store.read(query) }
    @store.append([DcbEventStore::Event.new(type: "A"), DcbEventStore::Event.new(type: "B")])

    result = DcbEventStore::DecisionModel.build(stale, snapshots: DcbEventStore::Snapshots::InMemorySnapshotStore.new)

    assert_empty result.states
    assert_equal 1, result.append_condition.after
  end

  # The head is taken before the reads and bounds them: an append that
  # lands in between shows up in a read but was not covered by the reads
  # issued earlier, so it is neither folded nor guarded.
  def test_events_past_the_head_taken_before_the_reads_are_not_folded
    store = @store
    stale = Object.new
    stale.define_singleton_method(:last_position) { 1 }
    stale.define_singleton_method(:read) { |query| store.read(query) }
    stale.define_singleton_method(:read_from) { |query, after:| store.read_from(query, after: after) }
    @store.append([DcbEventStore::Event.new(type: "A", tags: ["t:1"]),
                   DcbEventStore::Event.new(type: "A", tags: ["t:1"])])
    proj = projection(event_types: ["A"], tags: ["t:1"], handlers: { "A" => ->(s, _e) { s + 1 } })
    proj = DcbEventStore::Projection.new(initial_state: 0, handlers: proj.handlers, query: proj.query,
                                         snapshot: DcbEventStore::Snapshot.new(name: "a", version: 1))
    snapshots = DcbEventStore::Snapshots::InMemorySnapshotStore.new

    result = DcbEventStore::DecisionModel.build(stale, snapshots: snapshots, p: proj)

    assert_equal 1, result.states[:p]
    assert_equal 1, result.append_condition.after
    assert_equal 1, snapshots.fetch(proj.snapshot.key(proj.query)).position
  end

  # An empty store at the time the head is taken bounds every read to
  # nothing, however much was appended before the reads ran.
  def test_an_empty_head_bounds_the_reads_to_nothing
    store = @store
    stale = Object.new
    stale.define_singleton_method(:last_position) { nil }
    stale.define_singleton_method(:read) { |query| store.read(query) }
    stale.define_singleton_method(:read_from) { |query, after:| store.read_from(query, after: after) }
    @store.append([DcbEventStore::Event.new(type: "A", tags: ["t:1"])])
    proj = projection(event_types: ["A"], tags: ["t:1"], handlers: { "A" => ->(s, _e) { s + 1 } })

    result = DcbEventStore::DecisionModel.build(stale, snapshots: DcbEventStore::Snapshots::InMemorySnapshotStore.new,
                                                       p: proj)

    assert_equal 0, result.states[:p]
    assert_nil result.append_condition.after
  end
end
