require_relative "../test_helper"
require "minitest/mock"

class TestAppsignalSubscriber < Minitest::Test
  cover "DcbEventStore::AppsignalSubscriber*"

  # Records the two AppSignal helpers the adapter uses, mirroring their
  # signatures in the appsignal gem.
  class FakeAppsignal
    attr_reader :counters, :distributions

    def initialize
      @counters = []
      @distributions = []
    end

    def increment_counter(name, value = 1.0, tags = {})
      @counters << [name, value, tags]
    end

    def add_distribution_value(name, value, tags = {})
      @distributions << [name, value, tags]
    end
  end

  def setup
    @appsignal = FakeAppsignal.new
    @subscriber = DcbEventStore::AppsignalSubscriber.new(appsignal: @appsignal)
  end

  def build_event(name: "append.dcb", payload: {}, started_at: 1.0, finished_at: 1.5, error: nil)
    DcbEventStore::Notifications::Event.new(
      name: name, payload: payload, started_at: started_at, finished_at: finished_at, error: error
    )
  end

  # --- duration and errors (every operation) ---

  def test_records_duration_distribution_in_ms_tagged_with_demodulized_store
    @subscriber.call(build_event(name: "read.dcb", payload: {store: "DcbEventStore::Store"}))

    assert_equal [["dcb.read.duration", 500.0, {store: "Store"}]], @appsignal.distributions
    assert_empty @appsignal.counters
  end

  def test_events_without_store_payload_have_no_tags
    @subscriber.call(build_event(name: "projection.dcb", payload: {event_types: ["A"]}))

    assert_equal [["dcb.projection.duration", 500.0, {}]], @appsignal.distributions
  end

  def test_error_increments_errors_counter_with_store_tag
    @subscriber.call(build_event(name: "read.dcb",
                                 payload: {store: "DcbEventStore::Store"},
                                 error: RuntimeError.new("boom")))

    assert_includes @appsignal.counters, ["dcb.read.errors", 1, {store: "Store"}]
  end

  def test_custom_prefix
    subscriber = DcbEventStore::AppsignalSubscriber.new(appsignal: @appsignal, prefix: "eventstore")

    subscriber.call(build_event(name: "read.dcb"))

    assert_equal "eventstore.read.duration", @appsignal.distributions[0][0]
  end

  # --- append ---

  def test_append_counts_events_actually_written
    @subscriber.call(build_event(payload: {store: "DcbEventStore::Store", event_count: 3, appended_count: 2}))

    assert_equal [["dcb.append.events", 2, {store: "Store"}]], @appsignal.counters
  end

  def test_append_with_nothing_written_counts_no_events
    @subscriber.call(build_event(payload: {appended_count: 0}))

    assert_empty @appsignal.counters
  end

  def test_condition_not_met_counts_a_conflict_and_an_error
    error = DcbEventStore::ConditionNotMet.new("conflicting event(s)")

    @subscriber.call(build_event(payload: {store: "DcbEventStore::Store", condition: true}, error: error))

    assert_includes @appsignal.counters, ["dcb.append.conflicts", 1, {store: "Store"}]
    assert_includes @appsignal.counters, ["dcb.append.errors", 1, {store: "Store"}]
  end

  def test_condition_not_met_subclasses_also_count_as_conflicts
    subclass = Class.new(DcbEventStore::ConditionNotMet)

    @subscriber.call(build_event(payload: {store: "DcbEventStore::Store"}, error: subclass.new("nope")))

    assert(@appsignal.counters.any? { |name, _, _| name == "dcb.append.conflicts" })
  end

  def test_non_conflict_append_error_is_not_counted_as_conflict
    @subscriber.call(build_event(error: RuntimeError.new("connection lost")))

    assert_includes @appsignal.counters, ["dcb.append.errors", 1, {}]
    refute(@appsignal.counters.any? { |name, _, _| name == "dcb.append.conflicts" })
  end

  # --- subscribe ---

  def test_live_per_event_delivery_records_delivered_and_lag_in_ms
    @subscriber.call(build_event(
                       name: "subscribe.dcb",
                       payload: {store: "DcbEventStore::Store", phase: :live, sequence_position: 7, lag: 0.25}
                     ))

    assert_equal [["dcb.subscribe.delivered", 1, {store: "Store", phase: :live}]], @appsignal.counters
    assert_includes @appsignal.distributions, ["dcb.subscribe.lag", 250.0, {store: "Store"}]
  end

  def test_catch_up_delivery_is_counted_but_records_no_lag
    @subscriber.call(build_event(
                       name: "subscribe.dcb",
                       payload: {phase: :catch_up, sequence_position: 1, lag: 3600.0}
                     ))

    assert_equal [["dcb.subscribe.delivered", 1, {phase: :catch_up}]], @appsignal.counters
    refute(@appsignal.distributions.any? { |name, _, _| name == "dcb.subscribe.lag" })
  end

  def test_live_batch_delivery_uses_event_count_and_max_lag
    @subscriber.call(build_event(
                       name: "subscribe.dcb",
                       payload: {phase: :live, event_count: 5, last_position: 12, max_lag: 0.1}
                     ))

    assert_equal [["dcb.subscribe.delivered", 5, {phase: :live}]], @appsignal.counters
    assert_includes @appsignal.distributions, ["dcb.subscribe.lag", 100.0, {}]
  end

  def test_empty_batch_round_records_nothing_but_duration
    @subscriber.call(build_event(name: "subscribe.dcb", payload: {phase: :live, event_count: 0}))

    assert_empty @appsignal.counters
    assert_equal ["dcb.subscribe.duration"], @appsignal.distributions.map(&:first)
  end

  # --- subscription wiring ---

  def test_attach_to_subscribes_to_dcb_events_only
    notifications = DcbEventStore::Notifications.new
    @subscriber.attach_to(notifications)

    notifications.instrument("read.dcb") { nil }
    notifications.instrument("unrelated.event") { nil }

    assert_equal ["dcb.read.duration"], @appsignal.distributions.map(&:first)
  end

  def test_attach_to_returns_subscription_usable_for_unsubscribe
    notifications = DcbEventStore::Notifications.new
    subscription = @subscriber.attach_to(notifications)

    notifications.unsubscribe(subscription)
    notifications.instrument("read.dcb") { nil }

    assert_empty @appsignal.distributions
  end

  def test_attach_to_defaults_to_global_instrumentation
    previous = DcbEventStore.instrumentation
    DcbEventStore.instrumentation = DcbEventStore::Notifications.new
    @subscriber.attach_to

    DcbEventStore.instrumentation.instrument("read.dcb") { nil }

    assert_equal ["dcb.read.duration"], @appsignal.distributions.map(&:first)
  ensure
    DcbEventStore.instrumentation = previous
  end

  def test_custom_pattern
    notifications = DcbEventStore::Notifications.new
    subscriber = DcbEventStore::AppsignalSubscriber.new(appsignal: @appsignal, pattern: "append.dcb")
    subscriber.attach_to(notifications)

    notifications.instrument("read.dcb") { nil }
    notifications.instrument("append.dcb") { nil }

    assert_equal ["dcb.append.duration"], @appsignal.distributions.map(&:first)
  end

  def test_raises_a_helpful_error_when_the_appsignal_gem_is_missing
    subscriber = DcbEventStore::AppsignalSubscriber.new

    error = assert_raises(LoadError) { subscriber.call(build_event) }

    assert_equal "DcbEventStore::AppsignalSubscriber requires the appsignal gem; add it to your Gemfile",
                 error.message
  end

  def test_lazily_requires_the_appsignal_gem_and_uses_its_module
    skip "appsignal constant already defined" if Object.const_defined?(:Appsignal)

    subscriber = DcbEventStore::AppsignalSubscriber.new
    fake_module = Module.new
    Object.const_set(:Appsignal, fake_module)

    loaded = nil
    # Succeed only for the appsignal require, so the resolved receiver is the
    # real Appsignal module (not the require's return value or a missing gem).
    subscriber.stub(:require, ->(name) { name == "appsignal" || raise(LoadError) }) do
      loaded = subscriber.send(:appsignal)
    end

    assert_same fake_module, loaded
  ensure
    Object.send(:remove_const, :Appsignal) if fake_module && Object.const_defined?(:Appsignal)
  end

  # --- end to end through a store ---

  def test_store_activity_produces_metrics
    previous = DcbEventStore.instrumentation
    DcbEventStore.instrumentation = DcbEventStore::Notifications.new
    @subscriber.attach_to

    store = DcbEventStore::InMemoryStore.new
    store.append([DcbEventStore::Event.new(type: "A"), DcbEventStore::Event.new(type: "B")])
    store.read(DcbEventStore::Query.all).to_a

    begin
      store.append([DcbEventStore::Event.new(type: "C")],
                   DcbEventStore::AppendCondition.new(fail_if_events_match: DcbEventStore::Query.all))
    rescue DcbEventStore::ConditionNotMet
      # expected
    end

    counters = @appsignal.counters.map(&:first)
    assert_includes counters, "dcb.append.events"
    assert_includes counters, "dcb.append.errors"
    assert_includes counters, "dcb.append.conflicts"
    assert_equal ["dcb.append.events", 2, {store: "InMemoryStore"}], @appsignal.counters[0]

    durations = @appsignal.distributions.map(&:first)
    assert_equal %w[dcb.append.duration dcb.read.duration dcb.append.duration], durations
  ensure
    DcbEventStore.instrumentation = previous
  end
end
