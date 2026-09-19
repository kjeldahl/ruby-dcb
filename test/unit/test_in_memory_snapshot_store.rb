require_relative "../test_helper"
require_relative "../support/snapshot_store_contract"

# Runs the shared snapshot-store contract against the process-local store, the
# same contract the SQLite (test/sqlite/) and PostgreSQL (test/integration/)
# snapshot stores run, plus the specifics of keeping the state in memory
# instead of serializing it.
class TestInMemorySnapshotStore < Minitest::Test
  cover "DcbEventStore::Snapshots::InMemorySnapshotStore*"

  include SnapshotStoreContract

  def setup
    @snapshots = DcbEventStore::Snapshots::InMemorySnapshotStore.new
  end

  def test_starts_empty
    assert_equal 0, @snapshots.size
  end

  def test_size_counts_distinct_keys
    @snapshots.store("a", position: 1, state: 1)
    @snapshots.store("a", position: 2, state: 2)
    @snapshots.store("b", position: 1, state: 1)

    assert_equal 2, @snapshots.size
  end

  def test_size_drops_on_delete_and_clear
    @snapshots.store("a", position: 1, state: 1)
    @snapshots.store("b", position: 1, state: 1)

    @snapshots.delete("a")
    assert_equal 1, @snapshots.size

    @snapshots.clear
    assert_equal 0, @snapshots.size
  end

  # Nothing is serialized, so a stored state is the very object handed in.
  # That is the point (no copying cost) and the hazard the class documents.
  def test_state_is_stored_by_reference
    state = { n: 1 }
    @snapshots.store("k", position: 1, state: state)

    assert_same state, @snapshots.fetch("k").state
  end

  # The documented hazard: a handler that mutates its state in place reaches
  # back into the stored snapshot, so a later fold starts from a state that
  # already carries this fold's changes.
  def test_in_place_mutation_of_a_stored_state_is_visible_through_the_store
    state = { n: 1 }
    @snapshots.store("k", position: 1, state: state)

    @snapshots.fetch("k").state[:n] += 1

    assert_equal({ n: 2 }, @snapshots.fetch("k").state)
  end

  # The documented remedy: a Snapshot with a Marshal dump:/load: pair hands
  # the store a serialized copy, so the state the projection folded and the
  # state the store holds are separate objects.
  def test_marshal_dump_and_load_isolate_the_stored_state
    snapshot = DcbEventStore::Snapshot.new(
      name: "isolated",
      dump: ->(state) { Marshal.dump(state) },
      load: ->(dumped) { Marshal.load(dumped) } # rubocop:disable Security/MarshalLoad
    )

    state = { n: 1 }
    @snapshots.store("k", position: 1, state: snapshot.dump(state))

    state[:n] = 99 # the projection keeps mutating its own state afterwards

    assert_equal({ n: 1 }, snapshot.load(@snapshots.fetch("k").state))
  end

  # The Hash is shared by every store in the process, so concurrent builders
  # writing the same key must not lose entries or roll one back.
  def test_concurrent_stores_keep_the_highest_position
    threads = (1..20).map do |i|
      Thread.new { @snapshots.store("k", position: i, state: { n: i }) }
    end
    threads.each(&:join)

    entry = @snapshots.fetch("k")
    assert_equal 20, entry.position
    assert_equal({ n: 20 }, entry.state)
  end
end
