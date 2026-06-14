require_relative "../test_helper"
require_relative "../support/instrumentation_contract"
require "stringio"

class TestNotifications < Minitest::Test
  cover "DcbEventStore::Notifications*"

  include InstrumentationContract

  def build_engine
    DcbEventStore::Notifications.new
  end

  # --- engine-specific behavior beyond the shared contract ---

  def test_multiple_subscribers_receive_the_same_event_object
    other = []
    collect
    track(@engine.subscribe { |event| other << event })

    @engine.instrument("op.dcb") { nil }

    assert_same @received[0], other[0]
  end

  def test_state_is_instance_local
    other_engine = build_engine
    collect("op.dcb")

    other_engine.instrument("op.dcb") { nil }

    assert_empty @received
    refute other_engine.listening?("op.dcb")
  end

  # With no matching subscriber, #instrument must skip timing and event
  # construction entirely (a documented optimization), so the block runs
  # once and the monotonic clock is never read.
  def test_skips_timing_when_no_subscriber_matches
    timed = 0
    @engine.define_singleton_method(:monotonic_time) do
      timed += 1
      0.0
    end

    result = @engine.instrument("op.dcb", n: 1) { |payload| payload[:n] + 1 }

    assert_equal 2, result
    assert_equal 0, timed
  end

  # The subscription list is replaced (copy-on-write) and kept frozen so
  # concurrent readers in #instrument iterate an immutable snapshot.
  def test_subscription_list_is_kept_frozen
    assert @engine.instance_variable_get(:@subscriptions).frozen?

    subscription = @engine.subscribe("op.dcb") { nil }
    assert @engine.instance_variable_get(:@subscriptions).frozen?

    @engine.unsubscribe(subscription)
    assert @engine.instance_variable_get(:@subscriptions).frozen?
  end

  # subscribe/unsubscribe mutate shared state, so both must take the mutex to
  # avoid lost updates when registrations race.
  def test_writes_are_synchronized_through_the_mutex
    mutex = @engine.instance_variable_get(:@mutex)
    synchronized = 0
    mutex.define_singleton_method(:synchronize) do |&block|
      synchronized += 1
      block.call
    end

    subscription = @engine.subscribe("op.dcb") { nil }
    @engine.unsubscribe(subscription)

    assert_equal 2, synchronized
  end
end
