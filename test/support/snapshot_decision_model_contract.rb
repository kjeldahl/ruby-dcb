# Shared behavioral contract for DecisionModel.build with a snapshot store.
#
# The invariant the whole feature rests on: snapshots are an optimization and
# nothing else. For any sequence of appends and builds, the states and the
# AppendCondition a build returns must be the same whether or not a snapshot
# store is handed to it -- only the reads get smaller.
#
# Around that: what a build writes (the +every+ policy, never moving a
# snapshot backwards), what it reads (one read per distinct snapshot position,
# projections without a snapshot reading their own query from the start),
# how a Snapshot's version and its dump/load pair are honored, and the
# snapshots_loaded/snapshots_written instrumentation payload.
#
# Including classes must set @store in setup and define #build_snapshot_store
# returning a fresh, empty snapshot store for the same backend.
module SnapshotDecisionModelContract
  Balance = Struct.new(:amount)

  # Records which read DecisionModel issued for each of its read groups.
  # Only the read side is delegated: appends go to @store directly.
  class ReadRecorder
    attr_reader :calls

    def initialize(store)
      @store = store
      @calls = []
    end

    def read(query)
      @calls << [:read, nil]
      @store.read(query)
    end

    def read_from(query, after:)
      @calls << [:read_from, after]
      @store.read_from(query, after: after)
    end

    def last_position = @store.last_position
  end

  # --- the invariant -------------------------------------------------------

  # A scripted run of interleaved appends and builds: at every step the build
  # that uses snapshots must agree with the build that does not in the states,
  # and its condition must guard the log head (never less than the plain
  # build's +after+, which stops at the last matching event).
  def test_states_and_after_identical_with_and_without_snapshots
    projections = {
      a: snap_counter("counter:a", snapshot: snap_config("a")),
      b: snap_counter("counter:b", snapshot: snap_config("b"))
    }

    assert_snapshotting_agrees(projections)

    snap_append("Increment", "counter:a")
    assert_snapshotting_agrees(projections)

    snap_append("Increment", "counter:b")
    snap_append("Increment", "counter:b")
    assert_snapshotting_agrees(projections)

    snap_append("Ignored", "counter:a")
    snap_append("Increment", "counter:c")
    assert_snapshotting_agrees(projections)

    snap_append("Increment", "counter:a")
    snap_append("Increment", "counter:b")
    assert_snapshotting_agrees(projections)
    assert_snapshotting_agrees(projections)
  end

  # The same invariant with only some projections snapshotted and an +every+
  # above one, so a build routinely runs on a snapshot that has fallen behind.
  def test_invariant_holds_with_mixed_and_lagging_snapshots
    projections = {
      a: snap_counter("counter:a", snapshot: snap_config("a", every: 3)),
      b: snap_counter("counter:b"),
      both: snap_counter("counter:a", type: "Other", snapshot: snap_config("both"))
    }

    6.times do |i|
      assert_snapshotting_agrees(projections)
      snap_append("Increment", "counter:a")
      snap_append(i.even? ? "Increment" : "Other", "counter:b")
      snap_append("Other", "counter:a")
    end

    assert_snapshotting_agrees(projections)
  end

  # The condition a snapshotted build returns must still reject an append that
  # raced it, exactly like the condition from a full build.
  def test_condition_from_a_snapshotted_build_still_guards_the_boundary
    snap_append("Increment", "counter:a")
    proj = { a: snap_counter("counter:a", snapshot: snap_config("a")) }

    DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, **proj)
    snap_append("Increment", "counter:a")

    result = DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, **proj)
    assert_equal 2, result.states[:a]

    # Someone else appends between the build and our append.
    snap_append("Increment", "counter:a")

    assert_raises(DcbEventStore::ConditionNotMet) do
      @store.append([DcbEventStore::Event.new(type: "Increment", tags: ["counter:a"])],
                    result.append_condition)
    end
  end

  # --- writing -------------------------------------------------------------

  def test_first_build_writes_a_snapshot_at_the_condition_position
    appended = snap_append("Increment", "counter:a")
    config = snap_config("a")
    proj = snap_counter("counter:a", snapshot: config)

    result = DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, a: proj)

    entry = snapshots.fetch(config.key(proj.query))
    refute_nil entry, "expected a snapshot to be written on the first build"
    assert_equal appended.last.sequence_position, entry.position
    assert_equal result.append_condition.after, entry.position
    assert_equal 1, entry.state
  end

  def test_nothing_is_written_for_a_projection_without_a_snapshot_config
    snap_append("Increment", "counter:a")
    proj = snap_counter("counter:a")

    DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, a: proj)

    assert_empty snapshots.fetch_many([DcbEventStore::Snapshot.new(name: "a").key(proj.query)])
  end

  def test_nothing_is_written_on_an_empty_store
    config = snap_config("a")
    proj = snap_counter("counter:a", snapshot: config)

    payload = snap_decision_payload { @result = DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, a: proj) }

    assert_nil @result.append_condition.after
    assert_equal 0, @result.states[:a]
    assert_nil snapshots.fetch(config.key(proj.query))
    assert_equal 0, payload[:snapshots_loaded]
    assert_equal 0, payload[:snapshots_written]
  end

  # --- which read each group gets --------------------------------------

  # Nothing to start from: the whole query is read from the beginning.
  def test_a_group_without_snapshots_is_read_in_full
    snap_append("Increment", "counter:a")
    recorder = ReadRecorder.new(@store)

    result = DcbEventStore::DecisionModel.build(recorder, snapshots: snapshots,
                                                          a: snap_counter("counter:a", snapshot: snap_config("a")))

    assert_equal [[:read, nil]], recorder.calls
    assert_equal 1, result.states[:a]
  end

  def test_a_snapshotted_group_is_read_from_after_its_position
    appended = snap_append("Increment", "counter:a")
    proj = snap_counter("counter:a", snapshot: snap_config("a"))
    DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, a: proj)

    recorder = ReadRecorder.new(@store)
    DcbEventStore::DecisionModel.build(recorder, snapshots: snapshots, a: proj)

    assert_equal [[:read_from, appended.last.sequence_position]], recorder.calls
  end

  def test_each_group_gets_its_own_read
    appended = snap_append("Increment", "counter:a")
    a = snap_counter("counter:a", snapshot: snap_config("a"))
    b = snap_counter("counter:b")
    DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, a: a)

    recorder = ReadRecorder.new(@store)
    DcbEventStore::DecisionModel.build(recorder, snapshots: snapshots, a: a, b: b)

    assert_equal [[:read_from, appended.last.sequence_position], [:read, nil]], recorder.calls
  end

  # No snapshot store at all: one read of the combined query, from the start.
  def test_a_build_without_a_snapshot_store_reads_once_from_the_start
    snap_append("Increment", "counter:a")
    recorder = ReadRecorder.new(@store)

    DcbEventStore::DecisionModel.build(recorder, a: snap_counter("counter:a"), b: snap_counter("counter:b"))

    assert_equal [[:read, nil]], recorder.calls
  end

  def test_snapshot_is_not_rewritten_when_no_events_were_added
    snap_append("Increment", "counter:a")
    config = snap_config("a")
    proj = snap_counter("counter:a", snapshot: config)

    DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, a: proj)
    first = snapshots.fetch(config.key(proj.query))

    payload = snap_decision_payload { DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, a: proj) }

    assert_equal 0, payload[:snapshots_written]
    assert_equal first.position, snapshots.fetch(config.key(proj.query)).position
  end

  # every: 3 -- the snapshot is left alone until three events have piled up on
  # top of it, then rewritten at the new position.
  def test_every_delays_the_rewrite_until_enough_events_piled_up
    snap_append("Increment", "counter:a")
    config = snap_config("a", every: 3)
    proj = snap_counter("counter:a", snapshot: config)
    key = config.key(proj.query)

    DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, a: proj)
    first = snapshots.fetch(key).position

    snap_append("Increment", "counter:a")
    DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, a: proj)
    assert_equal first, snapshots.fetch(key).position, "one new event must not rewrite an every: 3 snapshot"

    snap_append("Increment", "counter:a")
    DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, a: proj)
    assert_equal first, snapshots.fetch(key).position, "two new events must not rewrite an every: 3 snapshot"

    last = snap_append("Increment", "counter:a")
    result = DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, a: proj)

    entry = snapshots.fetch(key)
    assert_equal last.last.sequence_position, entry.position
    assert_equal 4, entry.state
    assert_equal 4, result.states[:a]

    # More than +every+ events on top rewrites it just the same: the policy
    # is a floor, not an exact count.
    4.times { snap_append("Increment", "counter:a") }
    latest = snap_append("Increment", "counter:a")
    DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, a: proj)

    entry = snapshots.fetch(key)
    assert_equal latest.last.sequence_position, entry.position
    assert_equal 9, entry.state
  end

  # The head moves past a snapshot through events the projection does not
  # even select; the snapshot follows anyway (state unchanged, position at
  # the head), so the next catch-up read starts where the log ends.
  def test_a_snapshot_follows_the_log_head_past_unrelated_events
    snap_append("Increment", "counter:a")
    config = snap_config("a", every: 2)
    proj = snap_counter("counter:a", snapshot: config)
    key = config.key(proj.query)

    DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, a: proj)
    first = snapshots.fetch(key).position

    snap_append("Increment", "counter:z")
    DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, a: proj)
    assert_equal first, snapshots.fetch(key).position, "one unrelated event is below every: 2"

    head = snap_append("Increment", "counter:z").last.sequence_position
    result = DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, a: proj)

    entry = snapshots.fetch(key)
    assert_equal head, entry.position
    assert_equal 1, entry.state
    assert_equal head, result.append_condition.after

    reads = snap_reads { DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, a: proj) }
    assert_equal head, reads[0].payload[:after]
  end

  # Two projections over the same events, one snapshotted and one not. The
  # snapshotless group reads from the start of the log, so the snapshotted
  # projection is handed events its snapshot already covers and must skip
  # every one of them, not only the one sitting exactly at its position.
  def test_a_snapshotted_projection_skips_every_event_its_snapshot_covers
    2.times { snap_append("Increment", "counter:a") }
    a = snap_counter("counter:a", snapshot: snap_config("a"))
    b = snap_counter("counter:a", snapshot: snap_config("b"))

    first = DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, a: a)
    assert_equal 2, first.states[:a]

    result = DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, a: a, b: b)

    assert_equal 2, result.states[:a], "events below the snapshot position were folded twice"
    assert_equal 2, result.states[:b]
    assert_equal first.append_condition.after, result.append_condition.after
  end

  # A snapshot already at (or past) the position this build guards is left
  # alone: a snapshot never moves backwards.
  def test_a_snapshot_is_never_written_to_a_position_that_is_not_ahead
    snap_append("Increment", "counter:a")
    config = snap_config("a")
    proj = snap_counter("counter:a", snapshot: config)
    key = config.key(proj.query)

    DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, a: proj)
    position = snapshots.fetch(key).position
    snapshots.store(key, position: position + 100, state: 41)

    DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, a: proj)

    entry = snapshots.fetch(key)
    assert_equal position + 100, entry.position
    assert_equal 41, entry.state
  end

  # --- loading -------------------------------------------------------------

  def test_events_after_the_snapshot_are_folded_on_top
    3.times { snap_append("Increment", "counter:a") }
    config = snap_config("a")
    proj = snap_counter("counter:a", snapshot: config)

    first = DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, a: proj)
    assert_equal 3, first.states[:a]

    appended = snap_append("Increment", "counter:a")
    second = DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, a: proj)

    assert_equal 4, second.states[:a]
    assert_equal appended.last.sequence_position, second.append_condition.after
  end

  # Nothing new since the snapshot: the read comes back empty and the position
  # the condition guards is the snapshot's own.
  def test_a_build_with_no_new_events_reads_nothing_and_reuses_the_position
    appended = snap_append("Increment", "counter:a")
    config = snap_config("a")
    proj = snap_counter("counter:a", snapshot: config)

    first = DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, a: proj)

    reads = snap_reads { @second = DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, a: proj) }

    assert_equal 1, reads.size, "expected exactly one read for one snapshot position"
    assert_equal 0, reads[0].payload[:event_count]
    assert_equal appended.last.sequence_position, reads[0].payload[:after]
    assert_equal first.states, @second.states
    assert_equal first.append_condition.after, @second.append_condition.after
    assert_equal appended.last.sequence_position, @second.append_condition.after
  end

  def test_a_second_build_reads_only_the_events_added_since
    3.times { snap_append("Increment", "counter:a") }
    proj = snap_counter("counter:a", snapshot: snap_config("a"))
    DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, a: proj)

    snap_append("Increment", "counter:a")
    reads = snap_reads { DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, a: proj) }

    assert_equal 1, reads.size
    assert_equal 1, reads[0].payload[:event_count]
  end

  # Projections at different snapshot positions are read in separate groups,
  # each starting after its own position.
  def test_two_projections_with_snapshots_at_different_positions
    snap_append("Increment", "counter:a")
    a = snap_counter("counter:a", snapshot: snap_config("a"))
    b = snap_counter("counter:b", snapshot: snap_config("b"))

    # a alone: its snapshot is taken now, b has none yet.
    DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, a: a)

    snap_append("Increment", "counter:a")
    snap_append("Increment", "counter:b")
    snap_append("Increment", "counter:b")

    reads = snap_reads { @result = DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, a: a, b: b) }

    assert_equal 2, reads.size, "expected one read per distinct snapshot position"
    assert_equal 2, @result.states[:a]
    assert_equal 2, @result.states[:b]

    plain = DcbEventStore::DecisionModel.build(@store, a: a, b: b)
    assert_equal plain.states, @result.states
    assert_equal plain.append_condition.after, @result.append_condition.after
  end

  # A projection without a snapshot reads its own query from the start of the
  # log while the snapshotted one catches up from its position.
  def test_projection_without_a_snapshot_works_alongside_one_with_it
    snap_append("Increment", "counter:a")
    snap_append("Increment", "counter:b")
    a = snap_counter("counter:a", snapshot: snap_config("a"))
    b = snap_counter("counter:b")

    first = DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, a: a, b: b)
    @a_snapshot_position = first.append_condition.after

    snap_append("Increment", "counter:a")
    snap_append("Increment", "counter:b")

    reads = snap_reads { @result = DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, a: a, b: b) }

    assert_equal 2, reads.size, "expected one read for the snapshot group and one for the snapshotless group"
    afters = reads.map { |read| read.payload[:after] }
    assert_equal 1, afters.count(&:nil?), "the snapshotless projection reads from the start of the log"
    assert_equal [@a_snapshot_position], afters.compact, "the snapshotted projection reads from its position"
    assert_equal 2, @result.states[:a]
    assert_equal 2, @result.states[:b]

    plain = DcbEventStore::DecisionModel.build(@store, a: a, b: b)
    assert_equal plain.states, @result.states
    assert_equal plain.append_condition.after, @result.append_condition.after
  end

  # An event selected by two groups' queries is read twice and folded once.
  def test_an_event_matching_two_groups_is_folded_once
    shared = snap_counter("counter:a", snapshot: snap_config("shared"))
    wide = snap_counter("counter:a", type: "Increment", snapshot: snap_config("wide"))

    snap_append("Increment", "counter:a")
    DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, shared: shared)

    snap_append("Increment", "counter:a")
    result = DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, shared: shared, wide: wide)

    assert_equal 2, result.states[:shared]
    assert_equal 2, result.states[:wide]
  end

  # --- versioning ----------------------------------------------------------

  def test_bumping_the_version_ignores_the_old_snapshot
    snap_append("Increment", "counter:a")
    v1 = snap_counter("counter:a", snapshot: snap_config("a", version: 1))
    DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, a: v1)

    # A handler change would give a different state; the version bump must
    # keep the v1 snapshot from being read.
    v2_config = snap_config("a", version: 2)
    v2 = DcbEventStore::Projection.new(
      initial_state: 0, handlers: { "Increment" => ->(s, _e) { s + 10 } },
      query: snap_query("Increment", "counter:a"), snapshot: v2_config
    )

    result = DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, a: v2)

    assert_equal 10, result.states[:a]
    refute_nil snapshots.fetch(v2_config.key(v2.query))
    refute_nil snapshots.fetch(snap_config("a", version: 1).key(v1.query))
  end

  # --- dump / load ---------------------------------------------------------

  def test_dump_and_load_round_trip_a_struct_state
    config = DcbEventStore::Snapshot.new(
      name: "balance",
      dump: ->(state) { { amount: state.amount } },
      load: ->(hash) { Balance.new(hash.fetch(:amount)) }
    )
    proj = DcbEventStore::Projection.new(
      initial_state: Balance.new(0),
      handlers: { "Deposited" => ->(s, e) { Balance.new(s.amount + e.data.fetch(:amount)) } },
      query: snap_query("Deposited", "account:1"),
      snapshot: config
    )

    snap_append("Deposited", "account:1", data: { amount: 30 })
    first = DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, balance: proj)
    assert_equal Balance.new(30), first.states[:balance]

    snap_append("Deposited", "account:1", data: { amount: 12 })
    second = DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, balance: proj)

    assert_equal Balance.new(42), second.states[:balance]
    assert_equal({ amount: 42 }, snapshots.fetch(config.key(proj.query)).state)
  end

  # A handler that mutates its state in place would otherwise reach back into
  # a stored snapshot (see InMemorySnapshotStore's note). A Marshal dump/load
  # pair hands the store a serialized copy, so what the store holds is its
  # own object whatever the projection does with its state afterwards.
  def test_marshal_dump_and_load_isolate_a_state_mutated_in_place
    config = DcbEventStore::Snapshot.new(
      name: "mutating",
      # Base64 so the dumped state is a plain JSON string for the SQL stores.
      dump: ->(state) { [Marshal.dump(state)].pack("m0") },
      load: ->(packed) { Marshal.load(packed.unpack1("m0")) } # rubocop:disable Security/MarshalLoad
    )
    proj = DcbEventStore::Projection.new(
      initial_state: { n: 0 },
      handlers: { "Increment" => ->(state, _e) {
        state[:n] += 1
        state
      } },
      query: snap_query("Increment", "counter:a"),
      snapshot: config
    )

    2.times { snap_append("Increment", "counter:a") }
    first = DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, a: proj)
    assert_equal({ n: 2 }, first.states[:a])

    # The projection keeps mutating the state object it was handed.
    first.states[:a][:n] = 999

    second = DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, a: proj)
    assert_equal({ n: 2 }, second.states[:a])
    refute_same first.states[:a], second.states[:a]
  end

  # --- instrumentation -----------------------------------------------------

  def test_decision_model_payload_reports_snapshots_loaded_and_written
    snap_append("Increment", "counter:a")
    proj = snap_counter("counter:a", snapshot: snap_config("a"))
    plain = snap_counter("counter:b")

    first = snap_decision_payload do
      DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, a: proj, b: plain)
    end
    assert_equal 0, first[:snapshots_loaded]
    assert_equal 1, first[:snapshots_written]

    snap_append("Increment", "counter:a")
    second = snap_decision_payload do
      DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, a: proj, b: plain)
    end
    assert_equal 1, second[:snapshots_loaded]
    assert_equal 1, second[:snapshots_written]

    third = snap_decision_payload do
      DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, a: proj, b: plain)
    end
    assert_equal 1, third[:snapshots_loaded]
    assert_equal 0, third[:snapshots_written]
  end

  def test_decision_model_payload_omits_the_snapshot_keys_without_a_store
    snap_append("Increment", "counter:a")

    payload = snap_decision_payload do
      DcbEventStore::DecisionModel.build(@store, a: snap_counter("counter:a", snapshot: snap_config("a")))
    end

    refute payload.key?(:snapshots_loaded)
    refute payload.key?(:snapshots_written)
  end

  def test_event_count_payload_counts_only_the_events_read
    3.times { snap_append("Increment", "counter:a") }
    proj = snap_counter("counter:a", snapshot: snap_config("a"))
    DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, a: proj)

    snap_append("Increment", "counter:a")
    payload = snap_decision_payload { DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, a: proj) }

    assert_equal 1, payload[:event_count]
  end

  private

  def snapshots
    @snapshots ||= build_snapshot_store
  end

  def snap_config(name, every: 1, version: 1)
    DcbEventStore::Snapshot.new(name: name, version: version, every: every)
  end

  def snap_query(type, tag)
    DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: [type], tags: [tag])])
  end

  def snap_counter(tag, type: "Increment", snapshot: nil)
    DcbEventStore::Projection.new(
      initial_state: 0,
      handlers: { type => ->(s, _e) { s + 1 } },
      query: snap_query(type, tag),
      snapshot: snapshot
    )
  end

  def snap_append(type, tag, data: {})
    @store.append([DcbEventStore::Event.new(type: type, data: data, tags: [tag])])
  end

  # Builds the same projections with and without the snapshot store and
  # asserts the two agree; the snapshotted build runs second so it also picks
  # up whatever the previous call stored.
  def assert_snapshotting_agrees(projections)
    plain = DcbEventStore::DecisionModel.build(@store, **projections)
    snapshotted = DcbEventStore::DecisionModel.build(@store, snapshots: snapshots, **projections)

    assert_equal plain.states, snapshotted.states, "states diverged once snapshots were used"
    # Wrapped in arrays so an empty store's nil == nil does not trip
    # Minitest's assert_equal-nil deprecation.
    assert_equal [@store.last_position], [snapshotted.append_condition.after],
                 "a snapshotted build must guard up to the log head"
    if plain.append_condition.after
      assert_operator plain.append_condition.after, :<=, snapshotted.append_condition.after
    end
    assert_equal plain.append_condition.fail_if_events_match,
                 snapshotted.append_condition.fail_if_events_match
    snapshotted
  end

  # The "read.dcb" events published while the block ran.
  def snap_reads(&block)
    snap_capture(&block).select { |event| event.name == "read.dcb" }
  end

  # The payload of the single "decision_model.dcb" event the block published.
  def snap_decision_payload(&block)
    events = snap_capture(&block).select { |event| event.name == "decision_model.dcb" }
    assert_equal 1, events.size
    events[0].payload
  end

  # Swaps in a fresh global Notifications instance for the block (named apart
  # from StoreContract's equivalent, since both contracts land in one class).
  def snap_capture
    previous = DcbEventStore.instrumentation
    DcbEventStore.instrumentation = DcbEventStore::Notifications.new
    seen = []
    DcbEventStore.instrumentation.subscribe { |event| seen << event }
    yield
    seen
  ensure
    DcbEventStore.instrumentation = previous
  end
end
