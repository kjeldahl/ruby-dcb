require_relative "../test_helper"
require_relative "../support/instrumentation_contract"
require "active_support"
require "active_support/notifications"
require "stringio"

# Runs the shared instrumentation contract against the
# ActiveSupport::Notifications-backed engine, proving it is a drop-in
# replacement for DcbEventStore::Notifications, then verifies the parts
# only this engine provides: native visibility to plain
# ActiveSupport::Notifications subscribers.
class TestActiveSupportInstrumentation < Minitest::Test
  cover "DcbEventStore::ActiveSupportInstrumentation*"

  include InstrumentationContract

  def build_engine
    DcbEventStore::ActiveSupportInstrumentation.new
  end

  def as_subscribe(pattern, &)
    subscription = ActiveSupport::Notifications.subscribe(pattern, &)
    @as_subscriptions << subscription
    subscription
  end

  def setup
    super
    @as_subscriptions = []
  end

  def teardown
    super
    @as_subscriptions.each { |s| ActiveSupport::Notifications.unsubscribe(s) }
  end

  # --- native ActiveSupport::Notifications interop ---

  def test_events_are_visible_to_plain_active_support_subscribers
    seen = []
    as_subscribe("append.dcb") { |event| seen << event }

    @engine.instrument("append.dcb", event_count: 2) { :ok }

    assert_equal 1, seen.size
    event = seen[0]
    assert_kind_of ActiveSupport::Notifications::Event, event
    assert_equal "append.dcb", event.name
    assert_equal 2, event.payload[:event_count]
    assert_operator event.duration, :>=, 0
  end

  def test_errors_follow_the_active_support_payload_convention
    seen = []
    as_subscribe("append.dcb") { |event| seen << event }

    error = assert_raises(DcbEventStore::ConditionNotMet) do
      @engine.instrument("append.dcb", condition: true) do
        raise DcbEventStore::ConditionNotMet, "conflicting event(s)"
      end
    end

    payload = seen[0].payload
    assert_equal ["DcbEventStore::ConditionNotMet", "conflicting event(s)"], payload[:exception]
    assert_same error, payload[:exception_object]
  end

  def test_dcb_subscribers_do_not_see_active_support_exception_keys
    collect

    assert_raises(RuntimeError) do
      @engine.instrument("op.dcb", a: 1) { raise "boom" }
    end

    # The error is surfaced through event.error (contract behavior); the
    # ActiveSupport bookkeeping keys are stripped from the payload.
    assert_equal({a: 1}, @received[0].payload)
    assert_instance_of RuntimeError, @received[0].error
  end

  def test_store_emissions_flow_through_active_support_notifications
    previous = DcbEventStore.instrumentation
    DcbEventStore.instrumentation = @engine

    seen = []
    as_subscribe(/\.dcb\z/) { |event| seen << event }

    store = DcbEventStore::InMemoryStore.new
    store.append([DcbEventStore::Event.new(type: "A")])
    store.read(DcbEventStore::Query.all).to_a

    assert_equal %w[append.dcb read.dcb], seen.map(&:name)
    assert_equal 1, seen[0].payload[:appended_count]
    assert_equal 1, seen[1].payload[:event_count]
  ensure
    DcbEventStore.instrumentation = previous
  end

  def test_nested_emissions_share_the_active_support_instrumenter
    previous = DcbEventStore.instrumentation
    DcbEventStore.instrumentation = @engine

    seen = []
    as_subscribe(/\.dcb\z/) { |event| seen << event }

    store = DcbEventStore::InMemoryStore.new
    store.append([DcbEventStore::Event.new(type: "Counted")])
    seen.clear

    projection = DcbEventStore::Projection.new(
      initial_state: 0,
      handlers: {"Counted" => ->(state, _event) { state + 1 }},
      query: DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: ["Counted"])])
    )
    DcbEventStore::DecisionModel.build(store, count: projection)

    # Inner spans finish first, and all events carry the same transaction
    # id, which is how ActiveSupport groups nested work.
    assert_equal %w[read.dcb projection.dcb decision_model.dcb], seen.map(&:name)
    assert_equal 1, seen.map(&:transaction_id).uniq.size
  ensure
    DcbEventStore.instrumentation = previous
  end
end
