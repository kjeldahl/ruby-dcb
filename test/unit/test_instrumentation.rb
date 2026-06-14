require_relative "../test_helper"
require "securerandom"

# Verifies the instrumentation events emitted by stores, projections and
# decision models. Each test swaps in a fresh Notifications instance so the
# global instrumentation of other tests is unaffected.
# Minimal instrumentation engine that records the names it is asked to
# instrument and answers #listening? with a fixed value, so tests can assert
# whether a code path consulted/used instrumentation at all.
class RecordingInstrumentation
  attr_reader :instrumented

  def initialize(listening:)
    @listening = listening
    @instrumented = []
  end

  def listening?(_name) = @listening

  def instrument(name, payload = {})
    @instrumented << name
    yield payload
  end
end

class InstrumentationTestCase < Minitest::Test
  def setup
    @events = []
    @previous_instrumentation = DcbEventStore.instrumentation
    DcbEventStore.instrumentation = DcbEventStore::Notifications.new
    DcbEventStore.instrumentation.subscribe { |event| @events << event }
  end

  def teardown
    DcbEventStore.instrumentation = @previous_instrumentation
  end
end

class TestStoreInstrumentationEmission < InstrumentationTestCase
  cover "DcbEventStore::InMemoryStore*"
  cover "DcbEventStore::StoreInstrumentation*"

  def setup
    super
    @store = DcbEventStore::InMemoryStore.new
  end

  def test_append_emits_event_with_counts_and_position
    @store.append([
                    DcbEventStore::Event.new(type: "A"),
                    DcbEventStore::Event.new(type: "A"),
                    DcbEventStore::Event.new(type: "B")
                  ])

    assert_equal ["append.dcb"], @events.map(&:name)
    payload = @events[0].payload
    assert_equal "DcbEventStore::InMemoryStore", payload[:store]
    assert_equal 3, payload[:event_count]
    assert_equal %w[A B], payload[:event_types]
    assert_equal false, payload[:condition]
    assert_equal 3, payload[:appended_count]
    assert_equal 3, payload[:last_position]
  end

  def test_append_reports_condition_presence
    query = DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: ["Other"])])
    condition = DcbEventStore::AppendCondition.new(fail_if_events_match: query)

    @store.append([DcbEventStore::Event.new(type: "A")], condition)

    assert_equal true, @events[0].payload[:condition]
    assert_nil @events[0].error
  end

  def test_append_of_duplicate_reports_zero_appended
    id = SecureRandom.uuid
    @store.append([DcbEventStore::Event.new(type: "A", id: id)])
    @store.append([DcbEventStore::Event.new(type: "A", id: id)])

    payload = @events[1].payload
    assert_equal 1, payload[:event_count]
    assert_equal 0, payload[:appended_count]
    assert_nil payload[:last_position]
  end

  def test_failed_append_condition_emits_event_with_error
    @store.append([DcbEventStore::Event.new(type: "Conflict")])
    query = DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: ["Conflict"])])
    condition = DcbEventStore::AppendCondition.new(fail_if_events_match: query)

    assert_raises(DcbEventStore::ConditionNotMet) do
      @store.append([DcbEventStore::Event.new(type: "Another")], condition)
    end

    event = @events.last
    assert_equal "append.dcb", event.name
    assert_equal true, event.payload[:condition]
    assert_instance_of DcbEventStore::ConditionNotMet, event.error
    assert_nil event.payload[:appended_count]
  end

  def test_read_emits_event_with_count_on_full_enumeration
    @store.append([DcbEventStore::Event.new(type: "A"), DcbEventStore::Event.new(type: "B")])
    @events.clear

    query = DcbEventStore::Query.all
    @store.read(query).to_a

    assert_equal ["read.dcb"], @events.map(&:name)
    payload = @events[0].payload
    assert_equal "DcbEventStore::InMemoryStore", payload[:store]
    assert_same query, payload[:query]
    assert_nil payload[:after]
    assert_equal 2, payload[:event_count]
  end

  def test_read_from_includes_after_position
    appended = @store.append([
                               DcbEventStore::Event.new(type: "A"),
                               DcbEventStore::Event.new(type: "B")
                             ])
    @events.clear

    query = DcbEventStore::Query.all
    @store.read_from(query, after: appended[0].sequence_position).to_a

    payload = @events[0].payload
    assert_same query, payload[:query]
    assert_equal appended[0].sequence_position, payload[:after]
    assert_equal 1, payload[:event_count]
  end

  def test_each_full_enumeration_emits_its_own_event
    @store.append([DcbEventStore::Event.new(type: "A")])
    @events.clear

    enum = @store.read(DcbEventStore::Query.all)
    enum.to_a
    enum.to_a

    assert_equal %w[read.dcb read.dcb], @events.map(&:name)
    assert(@events.all? { |e| e.payload[:event_count] == 1 })
  end

  def test_read_instrumented_for_a_pattern_specific_subscriber
    @store.append([DcbEventStore::Event.new(type: "A")])

    # Only a subscriber whose pattern matches READ_EVENT exactly is
    # listening; instrument_read must consult that exact name, not a
    # catch-all, so the read is still wrapped.
    DcbEventStore.instrumentation = DcbEventStore::Notifications.new
    received = []
    DcbEventStore.instrumentation.subscribe("read.dcb") { |event| received << event }

    @store.read(DcbEventStore::Query.all).to_a

    assert_equal ["read.dcb"], received.map(&:name)
  end

  def test_read_instrumentation_is_decided_when_the_read_is_issued
    @store.append([DcbEventStore::Event.new(type: "A")])

    # Nobody listening for read.dcb when the enumerator is built: the read
    # stays unwrapped, so a subscriber added later sees nothing.
    DcbEventStore.instrumentation = DcbEventStore::Notifications.new
    enum = @store.read(DcbEventStore::Query.all)

    late = []
    DcbEventStore.instrumentation.subscribe { |event| late << event }
    enum.to_a

    assert_empty late
  end

  def test_partially_consumed_read_reports_events_yielded_so_far
    @store.append([DcbEventStore::Event.new(type: "A"), DcbEventStore::Event.new(type: "B")])
    @events.clear

    @store.read(DcbEventStore::Query.all).first

    assert_equal ["read.dcb"], @events.map(&:name)
    assert_equal 1, @events[0].payload[:event_count]
  end
end

class TestSubscribeInstrumentation < InstrumentationTestCase
  cover "DcbEventStore::InMemoryStore*"
  cover "DcbEventStore::StoreInstrumentation*"

  def subscribe_events
    @events.select { |event| event.name == "subscribe.dcb" }
  end

  def test_per_event_mode_emits_one_event_per_delivery_with_lag
    store = DcbEventStore::InMemoryStore.new
    store.append([DcbEventStore::Event.new(type: "A"), DcbEventStore::Event.new(type: "B")])

    query = DcbEventStore::Query.all
    received = []
    store.subscribe(query) { |event| received << event }

    assert_equal 2, received.size
    emitted = subscribe_events
    assert_equal 2, emitted.size
    assert(emitted.all? { |e| e.payload[:phase] == :catch_up })
    assert_equal "DcbEventStore::InMemoryStore", emitted[0].payload[:store]
    assert_same query, emitted[0].payload[:query]
    assert_equal([1, 2], emitted.map { |e| e.payload[:sequence_position] })
    emitted.each do |e|
      assert_kind_of Float, e.payload[:lag]
      assert_operator e.payload[:lag], :>=, 0
    end
  end

  def test_per_event_mode_live_deliveries_use_live_phase
    store = DcbEventStore::InMemoryStore.new
    store.subscribe(DcbEventStore::Query.all) { |event| event }
    @events.clear

    store.append([DcbEventStore::Event.new(type: "A")])

    emitted = subscribe_events
    assert_equal 1, emitted.size
    assert_equal :live, emitted[0].payload[:phase]
    assert_equal 1, emitted[0].payload[:sequence_position]
  end

  def test_per_event_mode_handler_error_is_captured_and_propagated
    store = DcbEventStore::InMemoryStore.new
    store.append([DcbEventStore::Event.new(type: "A")])

    error = assert_raises(RuntimeError) do
      store.subscribe(DcbEventStore::Query.all) { |_event| raise "handler boom" }
    end

    assert_equal "handler boom", error.message
    emitted = subscribe_events
    assert_equal 1, emitted.size
    assert_same error, emitted[0].error
  end

  def test_batch_mode_emits_one_event_per_delivery_round
    store = DcbEventStore::InMemoryStore.new(subscribe_instrumentation: :batch)
    store.append([DcbEventStore::Event.new(type: "A"), DcbEventStore::Event.new(type: "B")])
    @events.clear

    query = DcbEventStore::Query.all
    store.subscribe(query) { |event| event }
    store.append([DcbEventStore::Event.new(type: "C")])

    emitted = subscribe_events
    assert_equal(%i[catch_up live], emitted.map { |e| e.payload[:phase] })

    catch_up = emitted[0].payload
    assert_equal "DcbEventStore::InMemoryStore", catch_up[:store]
    assert_equal :catch_up, catch_up[:phase]
    assert_equal 2, catch_up[:event_count]
    assert_equal 2, catch_up[:last_position]
    assert_kind_of Float, catch_up[:max_lag]
    assert_operator catch_up[:max_lag], :>=, 0
    assert_same query, catch_up[:query]

    live = emitted[1].payload
    assert_equal 1, live[:event_count]
    assert_equal 3, live[:last_position]
  end

  def test_batch_mode_empty_round_reports_zero_count
    store = DcbEventStore::InMemoryStore.new(subscribe_instrumentation: :batch)

    store.subscribe(DcbEventStore::Query.all) { |event| event }

    emitted = subscribe_events
    assert_equal 1, emitted.size
    assert_equal 0, emitted[0].payload[:event_count]
    assert_nil emitted[0].payload[:last_position]
    assert_nil emitted[0].payload[:max_lag]
  end

  def test_no_op_append_runs_no_delivery_round
    store = DcbEventStore::InMemoryStore.new(subscribe_instrumentation: :batch)
    id = SecureRandom.uuid
    store.subscribe(DcbEventStore::Query.all) { |event| event }
    store.append([DcbEventStore::Event.new(type: "A", id: id)])
    @events.clear

    # Re-appending the same id is idempotent: nothing is stored, so the
    # listeners must not be woken and no delivery round is emitted.
    store.append([DcbEventStore::Event.new(type: "A", id: id)])

    assert_empty subscribe_events
  end

  def test_instrumentation_is_decided_per_delivery_round
    store = DcbEventStore::InMemoryStore.new

    # Nobody listening for subscribe.dcb when the subscription starts:
    # later rounds are still instrumented once a subscriber appears.
    DcbEventStore.instrumentation = DcbEventStore::Notifications.new
    store.subscribe(DcbEventStore::Query.all) { |event| event }

    late = []
    DcbEventStore.instrumentation.subscribe("subscribe.dcb") { |event| late << event }
    store.append([DcbEventStore::Event.new(type: "A")])

    assert_equal 1, late.size
    assert_equal :live, late[0].payload[:phase]
  end

  def test_batch_mode_max_lag_reflects_oldest_event
    store = DcbEventStore::InMemoryStore.new(subscribe_instrumentation: :batch)
    store.append([DcbEventStore::Event.new(type: "A")])
    sleep 0.05
    store.append([DcbEventStore::Event.new(type: "B")])
    @events.clear

    store.subscribe(DcbEventStore::Query.all) { |event| event }

    emitted = subscribe_events
    assert_equal 1, emitted.size
    # A was stored ~0.05s before this catch-up round; max_lag must reflect
    # that oldest, largest lag rather than the most recently stored event.
    assert_operator emitted[0].payload[:max_lag], :>=, 0.04
  end

  def test_not_listening_delivers_without_instrumenting_subscribe
    spy = RecordingInstrumentation.new(listening: false)
    DcbEventStore.instrumentation = spy
    store = DcbEventStore::InMemoryStore.new
    received = []

    store.subscribe(DcbEventStore::Query.all) { |event| received << event }
    store.append([DcbEventStore::Event.new(type: "A")])

    # Delivery still happens, but with nobody listening the subscribe round
    # is not instrumented at all (no lag computed, no event published).
    assert_equal ["A"], received.map(&:type)
    refute_includes spy.instrumented, "subscribe.dcb"
  end

  def test_invalid_subscribe_instrumentation_mode_raises
    error = assert_raises(ArgumentError) do
      DcbEventStore::InMemoryStore.new(subscribe_instrumentation: :nope)
    end
    assert_equal "subscribe_instrumentation must be one of [:event, :batch], got :nope", error.message

    assert_raises(ArgumentError) do
      DcbEventStore::Store.new(nil, subscribe_instrumentation: :nope)
    end
  end
end

class TestProjectionInstrumentation < InstrumentationTestCase
  cover "DcbEventStore::Projection*"

  def test_fold_emits_event_with_types_and_count
    projection = DcbEventStore::Projection.new(
      initial_state: 0,
      handlers: {"A" => ->(state, _event) { state + 1 }},
      query: DcbEventStore::Query.all
    )

    result = projection.fold([DcbEventStore::Event.new(type: "A"), DcbEventStore::Event.new(type: "B")])

    assert_equal 1, result
    assert_equal ["projection.dcb"], @events.map(&:name)
    assert_equal ["A"], @events[0].payload[:event_types]
    assert_equal 2, @events[0].payload[:event_count]
  end

  def test_fold_of_no_events_emits_zero_count
    projection = DcbEventStore::Projection.new(
      initial_state: :initial,
      handlers: {},
      query: DcbEventStore::Query.all
    )

    assert_equal :initial, projection.fold([])
    assert_equal 0, @events[0].payload[:event_count]
  end
end

class TestDecisionModelInstrumentation < InstrumentationTestCase
  cover "DcbEventStore::DecisionModel*"

  def test_build_emits_event_with_projection_names_count_and_position
    store = DcbEventStore::InMemoryStore.new
    store.append([
                   DcbEventStore::Event.new(type: "Counted", tags: ["c:1"]),
                   DcbEventStore::Event.new(type: "Counted", tags: ["c:1"])
                 ])
    @events.clear

    projection = DcbEventStore::Projection.new(
      initial_state: 0,
      handlers: {"Counted" => ->(state, _event) { state + 1 }},
      query: DcbEventStore::Query.new([
                                        DcbEventStore::QueryItem.new(event_types: ["Counted"], tags: ["c:1"])
                                      ])
    )

    result = DcbEventStore::DecisionModel.build(store, count: projection)

    assert_equal 2, result.states[:count]
    # Nested events: the store read and projection fold complete inside build.
    assert_equal %w[read.dcb projection.dcb decision_model.dcb], @events.map(&:name)

    payload = @events.last.payload
    assert_equal [:count], payload[:projections]
    assert_equal 2, payload[:event_count]
    assert_equal 2, payload[:last_position]
  end

  def test_build_on_empty_store_reports_nil_last_position
    store = DcbEventStore::InMemoryStore.new
    projection = DcbEventStore::Projection.new(
      initial_state: 0,
      handlers: {"Counted" => ->(state, _event) { state + 1 }},
      query: DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: ["Counted"])])
    )

    DcbEventStore::DecisionModel.build(store, count: projection)

    payload = @events.last.payload
    assert_equal 0, payload[:event_count]
    assert_nil payload[:last_position]
  end
end
