require_relative "../test_helper"

# The instrumentation events snapshots and materialized streams publish:
# "snapshot.dcb" from DecisionModel around its snapshot store calls and
# "stream.dcb" from MaterializedStreams per read. Same fixture as
# test_instrumentation.rb: a fresh Notifications instance per test.
class TestSnapshotInstrumentation < Minitest::Test
  cover "DcbEventStore::DecisionModel*"
  cover "DcbEventStore::MaterializedStreams*"

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

  def counter(tag, snapshot: DcbEventStore::Snapshot.new(name: "counter", every: 2))
    DcbEventStore::Projection.new(
      initial_state: 0,
      handlers: { "Inc" => ->(s, _e) { s + 1 } },
      query: DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: ["Inc"], tags: [tag])]),
      snapshot: snapshot
    )
  end

  def inc(tag) = DcbEventStore::Event.new(type: "Inc", tags: [tag])

  def named(name) = @events.select { |e| e.name == name }

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

  # --- stream.dcb ---

  def test_read_reports_misses_then_hits_with_fetched_and_served_counts
    streams = DcbEventStore::MaterializedStreams.new(@store)
    query = DcbEventStore::Query.new([
                                       DcbEventStore::QueryItem.new(event_types: ["Inc"], tags: ["t:a"]),
                                       DcbEventStore::QueryItem.new(event_types: ["Inc"], tags: ["t:b"])
                                     ])
    @store.append([inc("t:a"), inc("t:b"), inc("t:c")])

    streams.read(query).to_a
    first = named("stream.dcb").first.payload
    assert_equal "DcbEventStore::MaterializedStreams", first[:store]
    assert_equal query, first[:query]
    assert_nil first[:after]
    assert_equal({ streams: 2, hits: 0, misses: 2, fetched_count: 2, event_count: 2, evicted: 0 },
                 first.slice(:streams, :hits, :misses, :fetched_count, :event_count, :evicted))

    @store.append([inc("t:a")])
    streams.read(query).to_a
    second = named("stream.dcb").last.payload
    assert_equal({ hits: 2, misses: 0, fetched_count: 1, event_count: 3 },
                 second.slice(:hits, :misses, :fetched_count, :event_count))
  end

  def test_read_from_reports_after_and_the_events_actually_served
    streams = DcbEventStore::MaterializedStreams.new(@store)
    query = DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: ["Inc"], tags: ["t:a"])])
    appended = @store.append([inc("t:a"), inc("t:a"), inc("t:a")])

    served = streams.read_from(query, after: appended[0].sequence_position).to_a

    assert_equal appended[1..].map(&:sequence_position), served.map(&:sequence_position)
    payload = named("stream.dcb").first.payload
    assert_equal appended[0].sequence_position, payload[:after]
    assert_equal({ fetched_count: 3, event_count: 2 }, payload.slice(:fetched_count, :event_count))
  end

  def test_evictions_are_counted
    streams = DcbEventStore::MaterializedStreams.new(@store, max_streams: 1)
    a = DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: ["Inc"], tags: ["t:a"])])
    b = DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: ["Inc"], tags: ["t:b"])])

    streams.read(a).to_a
    streams.read(b).to_a

    assert_equal([0, 1], named("stream.dcb").map { |e| e.payload[:evicted] })
  end

  def test_wrapped_store_reads_still_publish_read_events
    streams = DcbEventStore::MaterializedStreams.new(@store)
    query = DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: ["Inc"], tags: ["t:a"])])
    @store.append([inc("t:a")])

    streams.read(query).to_a
    streams.read(query).to_a

    reads = named("read.dcb")
    assert_equal(["DcbEventStore::InMemoryStore"] * 2, reads.map { |e| e.payload[:store] })
    assert_equal([nil, 1], reads.map { |e| e.payload[:after] })
    assert_equal([1, 0], reads.map { |e| e.payload[:event_count] })
  end

  def test_failing_store_read_publishes_the_error_and_propagates
    failing = Object.new
    def failing.read(_query) = raise(IOError, "store down")
    streams = DcbEventStore::MaterializedStreams.new(failing)
    query = DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: ["Inc"], tags: ["t:a"])])

    assert_raises(IOError) { streams.read(query) }

    event = named("stream.dcb").first
    assert_instance_of IOError, event.error
    refute event.payload.key?(:hits)
    assert_equal 0, streams.size
  end
end
