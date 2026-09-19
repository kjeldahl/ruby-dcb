# Shared behavioral contract for the snapshot stores
# (Snapshots::InMemorySnapshotStore, Snapshots::SqliteSnapshotStore,
# Snapshots::PostgresSnapshotStore).
#
# All three are key => Snapshot::Entry(position, state) maps with a
# forward-only write: a snapshot never moves back to an earlier position, so a
# slow builder racing a fast one cannot roll the snapshot back. The state must
# survive the round trip through whatever the backend persists it as (the SQL
# ones go through JSON), which pins the shape a projection state may have.
#
# Including classes must set @snapshots in setup to an empty snapshot store.
module SnapshotStoreContract
  # Everything a JSON-backed store must return unchanged: nested
  # symbol-keyed hashes, arrays, integers, booleans and strings.
  NESTED_STATE = {
    count: 3,
    open: true,
    closed: false,
    label: "café ✓",
    items: [1, 2, ["a", false], { name: "x", ok: true }],
    nested: { deep: { deeper: [7, "s", true] } }
  }.freeze

  def test_fetch_returns_nil_when_missing
    assert_nil @snapshots.fetch("absent/v1/Query.all")
  end

  def test_store_then_fetch_round_trips_position_and_state
    @snapshots.store("k/v1/Query.all", position: 42, state: NESTED_STATE)

    entry = @snapshots.fetch("k/v1/Query.all")

    assert_equal 42, entry.position
    assert_equal NESTED_STATE, entry.state
  end

  def test_store_round_trips_scalar_states
    [0, -1, 17, true, false, "", "plain", [], {}, [1, 2, 3]].each_with_index do |state, i|
      key = "scalar:#{i}"
      @snapshots.store(key, position: i + 1, state: state)

      assert_equal state, @snapshots.fetch(key).state, "state #{state.inspect} did not round trip"
    end
  end

  def test_fetch_many_returns_only_the_keys_that_have_an_entry
    @snapshots.store("a", position: 1, state: { n: 1 })
    @snapshots.store("b", position: 2, state: { n: 2 })

    found = @snapshots.fetch_many(%w[a b missing])

    assert_equal %w[a b], found.keys.sort
    assert_equal 1, found["a"].position
    assert_equal({ n: 2 }, found["b"].state)
  end

  def test_fetch_many_with_no_keys_returns_an_empty_hash
    @snapshots.store("a", position: 1, state: { n: 1 })

    assert_empty @snapshots.fetch_many([])
  end

  def test_fetch_many_with_only_unknown_keys_returns_an_empty_hash
    assert_empty @snapshots.fetch_many(%w[nope also_nope])
  end

  def test_store_at_a_higher_position_replaces_the_entry
    @snapshots.store("k", position: 5, state: { n: 5 })
    @snapshots.store("k", position: 9, state: { n: 9 })

    entry = @snapshots.fetch("k")
    assert_equal 9, entry.position
    assert_equal({ n: 9 }, entry.state)
  end

  def test_store_at_a_lower_position_leaves_the_newer_entry
    @snapshots.store("k", position: 9, state: { n: 9 })
    @snapshots.store("k", position: 5, state: { n: 5 })

    entry = @snapshots.fetch("k")
    assert_equal 9, entry.position
    assert_equal({ n: 9 }, entry.state)
  end

  def test_store_at_the_same_position_leaves_the_entry_as_is
    @snapshots.store("k", position: 7, state: { n: "first" })
    @snapshots.store("k", position: 7, state: { n: "second" })

    entry = @snapshots.fetch("k")
    assert_equal 7, entry.position
    assert_equal({ n: "first" }, entry.state)
  end

  def test_store_returns_nil
    assert_nil @snapshots.store("k", position: 1, state: { n: 1 })
  end

  def test_delete_removes_one_entry_and_leaves_the_others
    @snapshots.store("a", position: 1, state: { n: 1 })
    @snapshots.store("b", position: 2, state: { n: 2 })

    assert_nil @snapshots.delete("a")
    assert_nil @snapshots.fetch("a")
    refute_nil @snapshots.fetch("b")
  end

  def test_delete_of_an_unknown_key_is_a_no_op
    assert_nil @snapshots.delete("never stored")
    assert_empty @snapshots.fetch_many(["never stored"])
  end

  # A deleted key is gone, not merely blanked: the forward-only guard must not
  # keep a later store at a lower position out.
  def test_store_after_delete_starts_over_at_any_position
    @snapshots.store("k", position: 9, state: { n: 9 })
    @snapshots.delete("k")
    @snapshots.store("k", position: 1, state: { n: 1 })

    entry = @snapshots.fetch("k")
    assert_equal 1, entry.position
    assert_equal({ n: 1 }, entry.state)
  end

  def test_clear_removes_every_entry
    @snapshots.store("a", position: 1, state: { n: 1 })
    @snapshots.store("b", position: 2, state: { n: 2 })

    assert_nil @snapshots.clear

    assert_nil @snapshots.fetch("a")
    assert_nil @snapshots.fetch("b")
    assert_empty @snapshots.fetch_many(%w[a b])
  end

  def test_clear_on_an_empty_store_is_a_no_op
    assert_nil @snapshots.clear
    assert_nil @snapshots.fetch("a")
  end

  # The keys DecisionModel derives carry the projection's query, so they
  # contain brackets, braces, commas, slashes and non-ASCII characters.
  def test_keys_built_from_a_query_round_trip
    query = DcbEventStore::Query.new([
                                       DcbEventStore::QueryItem.new(event_types: %w[A B],
                                                                    tags: [
                                                                      "course:c1", "student:s'1"
                                                                    ])
                                     ])
    key = DcbEventStore::Snapshot.new(name: "café/subs", version: 1).key(query)

    @snapshots.store(key, position: 3, state: { ok: true })

    assert_equal 3, @snapshots.fetch(key).position
    assert_equal({ ok: true }, @snapshots.fetch_many([key]).fetch(key).state)
  end

  # Two entries must not bleed into each other.
  def test_entries_are_independent
    @snapshots.store("a", position: 1, state: { n: "a" })
    @snapshots.store("b", position: 2, state: { n: "b" })
    @snapshots.store("a", position: 3, state: { n: "a2" })

    assert_equal({ n: "a2" }, @snapshots.fetch("a").state)
    assert_equal 2, @snapshots.fetch("b").position
    assert_equal({ n: "b" }, @snapshots.fetch("b").state)
  end

  def test_fetch_returns_a_snapshot_entry
    @snapshots.store("k", position: 1, state: { n: 1 })

    assert_instance_of DcbEventStore::Snapshot::Entry, @snapshots.fetch("k")
  end

  # --- purge ---

  def with_epoch(epoch)
    previous = DcbEventStore::Snapshots.epoch
    DcbEventStore::Snapshots.epoch = epoch
    yield
  ensure
    DcbEventStore::Snapshots.epoch = previous
  end

  def purge_key(name, version, tag, epoch: nil)
    with_epoch(epoch) do
      DcbEventStore::Snapshot.new(name: name, version: version)
                             .key(DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: ["E"],
                                                                                         tags: [tag])]))
    end
  end

  def seed_versions
    { "count/v1/a" => purge_key("count", 1, "t:a"), "count/v1/b" => purge_key("count", 1, "t:b"),
      "count/v2/a" => purge_key("count", 2, "t:a"), "count/v10/a" => purge_key("count", 10, "t:a"),
      "counter/v1/a" => purge_key("counter", 1, "t:a") }.each_value do |key|
      @snapshots.store(key, position: 1, state: 0)
    end
  end

  def remaining(keys)
    keys.values.select { |key| @snapshots.fetch(key) }.map { |key| keys.key(key) }
  end

  def test_purge_removes_every_version_of_a_name_and_nothing_else
    keys = seed_versions
    with_epoch(nil) do
      assert_equal 4, @snapshots.purge(name: "count")
    end

    # "counter" shares the prefix "count" but not the prefix "count/".
    assert_equal ["counter/v1/a"], remaining(keys)
  end

  def test_purge_keeps_one_version
    keys = seed_versions
    with_epoch(nil) do
      assert_equal 2, @snapshots.purge(name: "count", keep_version: 1)
    end

    # v10 must not survive as a prefix match of v1.
    assert_equal ["count/v1/a", "count/v1/b", "counter/v1/a"], remaining(keys)
  end

  def test_purge_of_an_unknown_name_removes_nothing
    keys = seed_versions
    with_epoch(nil) do
      assert_equal 0, @snapshots.purge(name: "nothing")
    end

    assert_equal keys.keys, remaining(keys)
  end

  def test_purge_stays_within_the_current_epoch
    old = purge_key("count", 1, "t:a", epoch: "old")
    current = purge_key("count", 1, "t:a", epoch: "new")
    @snapshots.store(old, position: 1, state: 0)
    @snapshots.store(current, position: 1, state: 0)

    with_epoch("new") { assert_equal 1, @snapshots.purge(name: "count") }

    refute_nil @snapshots.fetch(old)
    assert_nil @snapshots.fetch(current)
  end

  def test_purge_other_epochs_keeps_only_the_current_one
    keys = { unversioned: purge_key("count", 1, "t:a"), old: purge_key("count", 1, "t:a", epoch: "old"),
             current: purge_key("count", 1, "t:a", epoch: "new"), other: purge_key("x", 1, "t:a", epoch: "new") }
    keys.each_value { |key| @snapshots.store(key, position: 1, state: 0) }

    with_epoch("new") { assert_equal 2, @snapshots.purge_other_epochs }

    assert_nil @snapshots.fetch(keys[:unversioned])
    assert_nil @snapshots.fetch(keys[:old])
    refute_nil @snapshots.fetch(keys[:current])
    refute_nil @snapshots.fetch(keys[:other])
  end

  def test_purge_other_epochs_needs_an_epoch
    @snapshots.store("count/v1/x", position: 1, state: 0)

    with_epoch(nil) do
      error = assert_raises(ArgumentError) { @snapshots.purge_other_epochs }
      assert_match(/epoch/, error.message)
    end
    refute_nil @snapshots.fetch("count/v1/x")
  end

  # An epoch that happens to read like a prefix of another must not match
  # it: "rel-1/" is not a prefix of "rel-10/...".
  def test_purge_other_epochs_matches_the_whole_epoch
    ten = purge_key("count", 1, "t:a", epoch: "rel-10")
    @snapshots.store(ten, position: 1, state: 0)

    with_epoch("rel-1") { assert_equal 1, @snapshots.purge_other_epochs }

    assert_nil @snapshots.fetch(ten)
  end
end
