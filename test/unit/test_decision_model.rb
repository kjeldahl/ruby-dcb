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

  def snapshotted(name, query_item, every: 1)
    DcbEventStore::Projection.new(initial_state: 0, handlers: { "A" => ->(s, _e) { s + 1 } },
                                  query: DcbEventStore::Query.new([query_item]),
                                  snapshot: DcbEventStore::Snapshot.new(name: name, version: 1, every: every))
  end

  # Delegates reads to the store and answers every settle check with
  # +settled+, recording what each call asked.
  def settling(store, settled)
    calls = []
    duck = Object.new
    duck.define_singleton_method(:last_position) { store.last_position }
    duck.define_singleton_method(:read) { |query| store.read(query) }
    duck.define_singleton_method(:read_from) { |query, after:| store.read_from(query, after: after) }
    duck.define_singleton_method(:settled) do |checks|
      calls << checks.map { |c| [c.query, c.after, c.through, c.count] }
      checks.map { settled }
    end
    [duck, calls]
  end

  # A due snapshot is written only once the event store vouches that what
  # the build folded is every match up to it (issue #55), asked with the
  # projection's query, its old snapshot position, the new one and how
  # many events were folded in between.
  def test_a_snapshot_the_store_does_not_settle_is_not_written
    proj = snapshotted("a", DcbEventStore::QueryItem.new(event_types: ["A"]))
    snapshots = DcbEventStore::Snapshots::InMemorySnapshotStore.new
    key = proj.snapshot.key(proj.query)
    snapshots.store(key, position: 1, state: 1)
    3.times { @store.append([DcbEventStore::Event.new(type: "A")]) }
    store, calls = settling(@store, false)

    result = DcbEventStore::DecisionModel.build(store, snapshots: snapshots, p: proj)

    assert_equal 3, result.states[:p]
    assert_equal 1, snapshots.fetch(key).position
    assert_equal [[[proj.query, 1, 3, 2]]], calls
  end

  def test_a_snapshot_the_store_settles_is_written
    proj = snapshotted("a", DcbEventStore::QueryItem.new(event_types: ["A"]))
    snapshots = DcbEventStore::Snapshots::InMemorySnapshotStore.new
    @store.append([DcbEventStore::Event.new(type: "A")])
    store, calls = settling(@store, true)

    DcbEventStore::DecisionModel.build(store, snapshots: snapshots, p: proj)

    assert_equal 1, snapshots.fetch(proj.snapshot.key(proj.query)).position
    assert_equal [[[proj.query, nil, 1, 1]]], calls
  end

  # Only due snapshots are checked.
  def test_a_snapshot_that_is_not_due_is_not_checked
    proj = snapshotted("a", DcbEventStore::QueryItem.new(event_types: ["A"]), every: 5)
    snapshots = DcbEventStore::Snapshots::InMemorySnapshotStore.new
    snapshots.store(proj.snapshot.key(proj.query), position: 1, state: 1)
    2.times { @store.append([DcbEventStore::Event.new(type: "A")]) }
    store, calls = settling(@store, true)

    DcbEventStore::DecisionModel.build(store, snapshots: snapshots, p: proj)

    assert_empty calls
  end

  # A projection can fold an event past the position its own read covered:
  # another group's read, issued later, returned it. Its state then holds
  # more than a snapshot at that position may, so none is written, whatever
  # the store would say.
  def test_a_snapshot_is_not_written_below_an_event_it_folded
    a = snapshotted("a", DcbEventStore::QueryItem.new(event_types: ["A"], tags: ["t:1"]))
    all_a = DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: ["A"])])
    b = DcbEventStore::Projection.new(initial_state: 0, handlers: {}, query: all_a)
    snapshots = DcbEventStore::Snapshots::InMemorySnapshotStore.new
    key = a.snapshot.key(a.query)
    snapshots.store(key, position: 1, state: 1)
    3.times { @store.append([DcbEventStore::Event.new(type: "A", tags: ["t:1"])]) }
    store, calls = settling(@store, true)
    inner = @store
    # a's read (after its snapshot) misses position 3, which b's whole-log
    # read returns.
    store.define_singleton_method(:read_from) do |query, after:|
      inner.read_from(query, after: after).reject { |e| e.sequence_position == 3 }
    end

    result = DcbEventStore::DecisionModel.build(store, snapshots: snapshots, a: a, b: b)

    assert_equal 3, result.states[:a]
    assert_equal 1, snapshots.fetch(key).position
    assert_empty calls
  end
end
