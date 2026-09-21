require_relative "../test_helper"

# The "snapshot.dcb" events DecisionModel publishes around its snapshot
# store calls. Same fixture as test_instrumentation.rb: a fresh
# Notifications instance per test.
class TestSnapshotInstrumentation < Minitest::Test
  cover "DcbEventStore::DecisionModel*"

  def setup
    @events = []
    @previous_instrumentation = DcbEventStore.instrumentation
    DcbEventStore.instrumentation = DcbEventStore::Notifications.new
    DcbEventStore.instrumentation.subscribe { |event| @events << event }
    @store = DcbEventStore::InMemoryStore.new
    @snapshots = DcbEventStore::Snapshots::InMemorySnapshotStore.new
  end

  def teardown
    DcbEventStore.instrumentation = @previous_instrumentation
  end

  def counter(tag, snapshot: DcbEventStore::Snapshot.new(name: "counter", version: 1, every: 2))
    DcbEventStore::Projection.new(
      initial_state: 0,
      handlers: { "Inc" => ->(s, _e) { s + 1 } },
      query: DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: ["Inc"], tags: [tag])]),
      snapshot: snapshot
    )
  end

  def inc(tag) = DcbEventStore::Event.new(type: "Inc", tags: [tag])

  def named(name) = @events.select { |e| e.name == name }

  def snapshot_payload_values(key) = named("snapshot.dcb").map { |e| e.payload[key] }

  def build(**projections)
    DcbEventStore::DecisionModel.build(@store, snapshots: @snapshots, **projections)
  end

  # --- snapshot.dcb ---

  def test_load_reports_requested_and_loaded_counts
    @store.append([inc("t:a")])
    build(a: counter("t:a"), b: counter("t:b"), c: counter("t:c", snapshot: nil))
    @events.clear

    build(a: counter("t:a"), b: counter("t:b"), c: counter("t:c", snapshot: nil))

    load = named("snapshot.dcb").find { |e| e.payload[:operation] == :load }
    assert_equal "DcbEventStore::Snapshots::InMemorySnapshotStore", load.payload[:store]
    assert_equal %i[a b], load.payload[:projections]
    assert_equal 2, load.payload[:requested]
    assert_equal 2, load.payload[:loaded]
    assert_nil load.error
  end

  # namespace: names the snapshot store's namespace, nil in the default
  # one and for a snapshot store that has no such notion.
  def test_load_and_write_carry_the_snapshot_stores_namespace
    @store.append([inc("t:a")])
    build(a: counter("t:a"))
    events = named("snapshot.dcb")

    assert_equal %i[load write], snapshot_payload_values(:operation)
    assert(events.all? { |e| e.payload.key?(:namespace) && e.payload[:namespace].nil? })

    @events.clear
    @snapshots = DcbEventStore::Snapshots::InMemorySnapshotStore.new(namespace: "billing")
    build(a: counter("t:a"))

    assert_equal %w[billing billing], snapshot_payload_values(:namespace)

    @events.clear
    @snapshots = Class.new(DcbEventStore::Snapshots::InMemorySnapshotStore) { undef_method :namespace }.new
    build(a: counter("t:a"))

    assert_equal [nil, nil], snapshot_payload_values(:namespace)
  end

  def test_load_counts_only_the_snapshots_that_exist
    @store.append([inc("t:a")])
    build(a: counter("t:a"))
    @events.clear

    build(a: counter("t:a"), b: counter("t:b"))

    load = named("snapshot.dcb").find { |e| e.payload[:operation] == :load }
    assert_equal({ requested: 2, loaded: 1 }, load.payload.slice(:requested, :loaded))
  end

  def test_no_load_event_without_snapshot_store_or_configured_projections
    @store.append([inc("t:a")])
    DcbEventStore::DecisionModel.build(@store, a: counter("t:a"))
    build(a: counter("t:a", snapshot: nil))

    assert_empty named("snapshot.dcb")
  end

  def test_write_reports_projection_key_position_and_folded_count
    appended = @store.append([inc("t:a"), inc("t:a"), inc("t:b")])

    build(a: counter("t:a"), b: counter("t:b"))

    writes = named("snapshot.dcb").select { |e| e.payload[:operation] == :write }
    assert_equal(%i[a b], writes.map { |e| e.payload[:projection] })
    a = writes.first.payload
    assert_equal "DcbEventStore::Snapshots::InMemorySnapshotStore", a[:store]
    assert_equal 'counter/v1/[[["Inc"],["t:a"]]]', a[:key]
    assert_equal appended.last.sequence_position, a[:position]
    assert_equal 2, a[:folded_count]
    assert_equal 1, writes.last.payload[:folded_count]
  end

  def test_no_write_event_when_the_policy_holds_the_snapshot_back
    @store.append([inc("t:a")])
    build(a: counter("t:a"))
    @store.append([inc("t:a")])
    @events.clear

    build(a: counter("t:a")) # every: 2, only one new event

    assert_empty(named("snapshot.dcb").select { |e| e.payload[:operation] == :write })
    assert_equal 1, named("decision_model.dcb").size
    assert_equal({ snapshots_loaded: 1, snapshots_written: 0 },
                 named("decision_model.dcb").first.payload.slice(:snapshots_loaded, :snapshots_written))
  end

  def test_failing_snapshot_store_publishes_the_error_and_propagates
    failing = Object.new
    def failing.fetch_many(_keys) = raise(IOError, "snapshot store down")

    @store.append([inc("t:a")])
    assert_raises(IOError) { DcbEventStore::DecisionModel.build(@store, snapshots: failing, a: counter("t:a")) }

    load = named("snapshot.dcb").first
    assert_equal :load, load.payload[:operation]
    assert_instance_of IOError, load.error
    assert_nil load.payload[:loaded]
  end

  def test_write_events_wrap_the_store_call
    order = []
    @snapshots.define_singleton_method(:store) do |*args, **kw|
      order << :stored
      super(*args, **kw)
    end
    DcbEventStore.instrumentation.subscribe("snapshot.dcb") { |e| order << e.payload[:operation] }
    @store.append([inc("t:a")])

    build(a: counter("t:a"))

    assert_equal %i[load stored write], order
  end
end
