require_relative "../test_helper"
require "stringio"

class TestLogSubscriber < Minitest::Test
  cover "DcbEventStore::LogSubscriber*"

  def setup
    @io = StringIO.new
    @logger = Logger.new(@io)
  end

  def build_event(name: "append.dcb", payload: {}, started_at: 1.0, finished_at: 1.5123456, error: nil)
    DcbEventStore::Notifications::Event.new(
      name: name, payload: payload, started_at: started_at, finished_at: finished_at, error: error
    )
  end

  def test_logs_info_line_with_name_duration_and_payload
    subscriber = DcbEventStore::LogSubscriber.new(logger: @logger)

    subscriber.call(build_event(payload: {event_count: 2, event_types: %w[A B]}))

    assert_includes @io.string, "INFO"
    assert_includes @io.string, "append.dcb (512.35ms) event_count=2 event_types=[A,B]"
  end

  def test_logs_error_line_with_error_class_and_message
    subscriber = DcbEventStore::LogSubscriber.new(logger: @logger)
    error = DcbEventStore::ConditionNotMet.new("conflicting event(s)")

    subscriber.call(build_event(error: error))

    assert_includes @io.string, "ERROR"
    assert_includes @io.string, "append.dcb (512.35ms) error=DcbEventStore::ConditionNotMet conflicting event(s)"
  end

  def test_defaults_to_stdout_logger
    assert_output(/append\.dcb/) do
      DcbEventStore::LogSubscriber.new.call(build_event)
    end
  end

  def test_attach_to_subscribes_to_dcb_events_only
    notifications = DcbEventStore::Notifications.new
    DcbEventStore::LogSubscriber.new(logger: @logger).attach_to(notifications)

    notifications.instrument("append.dcb") { nil }
    notifications.instrument("unrelated.event") { nil }

    assert_includes @io.string, "append.dcb"
    refute_includes @io.string, "unrelated.event"
  end

  def test_attach_to_returns_subscription_usable_for_unsubscribe
    notifications = DcbEventStore::Notifications.new
    subscription = DcbEventStore::LogSubscriber.new(logger: @logger).attach_to(notifications)

    notifications.unsubscribe(subscription)
    notifications.instrument("append.dcb") { nil }

    assert_empty @io.string
  end

  def test_attach_to_defaults_to_global_instrumentation
    previous = DcbEventStore.instrumentation
    DcbEventStore.instrumentation = DcbEventStore::Notifications.new
    DcbEventStore::LogSubscriber.new(logger: @logger).attach_to

    DcbEventStore.instrumentation.instrument("read.dcb") { nil }

    assert_includes @io.string, "read.dcb"
  ensure
    DcbEventStore.instrumentation = previous
  end

  def test_custom_pattern
    notifications = DcbEventStore::Notifications.new
    DcbEventStore::LogSubscriber.new(logger: @logger, pattern: "read.dcb").attach_to(notifications)

    notifications.instrument("append.dcb") { nil }
    notifications.instrument("read.dcb") { nil }

    refute_includes @io.string, "append.dcb"
    assert_includes @io.string, "read.dcb"
  end
end
