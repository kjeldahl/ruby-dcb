require_relative "../test_helper"
require_relative "../support/postgres_database"
require_relative "../support/decision_model_contract"
require_relative "../support/snapshot_decision_model_contract"

# Runs the shared DecisionModel contract against PostgresStore; TestInMemoryStore
# runs the identical contract against InMemoryStore.
class TestDecisionModel < Minitest::Test
  cover "DcbEventStore::DecisionModel*"
  cover "DcbEventStore::Projection*"

  include PostgresDatabaseHelper
  include DecisionModelContract
  include SnapshotDecisionModelContract

  def setup
    setup_db
  end

  def teardown
    teardown_db
  end

  # For SnapshotDecisionModelContract: the snapshot table lives next to the
  # events in the test database, emptied for each test.
  def build_snapshot_store
    DcbEventStore::Snapshots::PostgresSnapshotStore.new(@conn).tap(&:clear)
  end
end

# PostgreSQL conditional appends on disjoint tags hold disjoint advisory
# locks and so commit out of sequence order: max(sequence_position) can lie
# past an in-flight append on the very tag a build is deciding about. A
# build with snapshots must therefore guard (and write its snapshots at) the
# last matching event it read, which the tag's lock keeps in order, never
# the head; otherwise the condition accepts an append it must reject and the
# snapshot never folds the in-flight event once it commits.
class TestDecisionModelPostgresGap < Minitest::Test
  include PostgresDatabaseHelper

  def setup
    setup_db
    @snapshots = DcbEventStore::Snapshots::PostgresSnapshotStore.new(@conn).tap(&:clear)
    @slow = PostgresDatabaseHelper.connection
    @fast = PostgresDatabaseHelper.connection
    @slow_open = false
  end

  def teardown
    @slow.exec("ROLLBACK") if @slow_open
    @slow&.close
    @fast&.close
    teardown_db
  end

  def query = DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: ["Sub"], tags: ["course:c1"])])

  def subscriptions
    DcbEventStore::Projection.new(initial_state: 0, handlers: { "Sub" => ->(s, _e) { s + 1 } }, query: query,
                                  snapshot: DcbEventStore::Snapshot.new(name: "subs", version: 1))
  end

  def sub(tag) = DcbEventStore::Event.new(type: "Sub", tags: [tag])

  # A conditional append on course:c1 that has taken its locks (what
  # PostgresStore#acquire_locks! takes for one event tagged course:c1 under
  # a condition on that tag) and its sequence position but not committed yet.
  def start_slow_append
    condition = DcbEventStore::AppendCondition.new(fail_if_events_match: query, after: 1)
    @slow.exec("BEGIN")
    @slow_open = true
    DcbEventStore::PostgresStore.new(@slow).send(:acquire_locks!, [sub("course:c1")], condition)
    @slow.exec_params(
      "INSERT INTO events (event_id, type, data, tags, schema_version) VALUES ($1, 'Sub', '{}', '{course:c1}', 1)",
      [SecureRandom.uuid]
    )
  end

  def commit_slow_append
    @slow.exec("COMMIT")
    @slow_open = false
  end

  def test_head_past_an_in_flight_append_on_the_same_tag
    @store.append([sub("course:c1")])                          # position 1
    start_slow_append                                          # position 2, uncommitted, holds lock c1
    DcbEventStore::PostgresStore.new(@fast).append([sub("course:c2")]) # position 3, committed

    result = DcbEventStore::DecisionModel.build(@store, snapshots: @snapshots, subs: subscriptions)
    plain = DcbEventStore::DecisionModel.build(@store, subs: subscriptions)
    assert_equal 1, result.states[:subs]
    assert_equal 1, plain.append_condition.after

    commit_slow_append # position 2 visible now

    assert_raises(DcbEventStore::ConditionNotMet) { @store.append([sub("course:c1")], plain.append_condition) }
    assert_raises(DcbEventStore::ConditionNotMet, "the snapshotted condition let an append past event 2") do
      @store.append([sub("course:c1")], result.append_condition)
    end

    rebuilt = DcbEventStore::DecisionModel.build(@store, snapshots: @snapshots, subs: subscriptions)
    assert_equal 2, rebuilt.states[:subs], "the snapshot never folds event 2"
  end
end
