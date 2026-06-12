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
end
