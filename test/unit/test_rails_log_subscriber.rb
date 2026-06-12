require_relative "../test_helper"
require "stringio"

class TestRailsLogSubscriber < Minitest::Test
  cover "DcbEventStore::RailsLogSubscriber*"

  def setup
    @io = StringIO.new
    @logger = Logger.new(@io)
  end

  # duration 0.51236s -> 512.36ms -> rounds to 512.4ms at one decimal, a
  # value that differs at round(0)/round(1)/round(2) so the rounding is pinned.
  def build_event(name: "append.dcb", payload: {}, started_at: 1.0, finished_at: 1.51236, error: nil)
    DcbEventStore::Notifications::Event.new(
      name: name, payload: payload, started_at: started_at, finished_at: finished_at, error: error
    )
  end

  # Strips ANSI escape sequences so assertions can target the visible text.
  def visible(string)
    string.gsub(/\e\[[0-9;]*m/, "")
  end

  def test_renders_activerecord_style_label_with_duration_and_payload
    subscriber = DcbEventStore::RailsLogSubscriber.new(logger: @logger)

    subscriber.call(build_event(payload: {store: "DcbEventStore::Store", event_count: 2}))

    line = visible(@io.string)
    assert_includes line, "DEBUG"
    assert_includes line, "  DCB Append (512.4ms)  store=DcbEventStore::Store event_count=2"
  end

  def test_humanizes_multiword_event_names
    subscriber = DcbEventStore::RailsLogSubscriber.new(logger: @logger)

    subscriber.call(build_event(name: "decision_model.dcb", payload: {projections: [:courses]}))

    assert_includes visible(@io.string), "DCB Decision Model (512.4ms)  projections=[courses]"
  end

  def test_logs_at_debug_level
    @logger.level = Logger::INFO
    subscriber = DcbEventStore::RailsLogSubscriber.new(logger: @logger)

    subscriber.call(build_event)

    assert_empty @io.string
  end

  def test_colorizes_label_and_body_by_default
    subscriber = DcbEventStore::RailsLogSubscriber.new(logger: @logger)

    subscriber.call(build_event(payload: {event_count: 1}))

    # Label is bold cyan, like ActiveRecord's bold query name...
    assert_includes @io.string, "#{DcbEventStore::RailsLogSubscriber::BOLD}#{DcbEventStore::RailsLogSubscriber::CYAN}"
    assert_includes @io.string, DcbEventStore::RailsLogSubscriber::MAGENTA
    assert_includes @io.string, DcbEventStore::RailsLogSubscriber::CLEAR
    # ...while the body is plain magenta, not bold.
    refute_includes @io.string, "#{DcbEventStore::RailsLogSubscriber::BOLD}#{DcbEventStore::RailsLogSubscriber::MAGENTA}"
  end

  def test_colorize_false_emits_plain_text
    subscriber = DcbEventStore::RailsLogSubscriber.new(logger: @logger, colorize: false)

    subscriber.call(build_event(payload: {event_count: 1}))

    refute_includes @io.string, "\e["
    assert_includes @io.string, "DCB Append (512.4ms)  event_count=1"
  end

  def test_error_events_render_in_red_with_error_detail
    subscriber = DcbEventStore::RailsLogSubscriber.new(logger: @logger)
    error = DcbEventStore::ConditionNotMet.new("conflicting event(s)")

    subscriber.call(build_event(payload: {condition: true}, error: error))

    # Both the label and the body switch to red (the label additionally bold).
    assert_includes @io.string, "#{DcbEventStore::RailsLogSubscriber::BOLD}#{DcbEventStore::RailsLogSubscriber::RED}"
    assert_includes @io.string,
                    "#{DcbEventStore::RailsLogSubscriber::RED}condition=true " \
                    "error=DcbEventStore::ConditionNotMet conflicting event(s)" \
                    "#{DcbEventStore::RailsLogSubscriber::CLEAR}"
    refute_includes @io.string, DcbEventStore::RailsLogSubscriber::CYAN
    refute_includes @io.string, DcbEventStore::RailsLogSubscriber::MAGENTA
    assert_includes visible(@io.string),
                    "DCB Append (512.4ms)  condition=true error=DcbEventStore::ConditionNotMet conflicting event(s)"
  end

  def test_formats_array_values_like_the_query_log
    subscriber = DcbEventStore::RailsLogSubscriber.new(logger: @logger, colorize: false)

    subscriber.call(build_event(payload: {event_types: %w[A B]}))

    assert_includes visible(@io.string), "event_types=[A,B]"
  end

  def test_attach_to_subscribes_to_dcb_events_only
    notifications = DcbEventStore::Notifications.new
    DcbEventStore::RailsLogSubscriber.new(logger: @logger).attach_to(notifications)

    notifications.instrument("append.dcb") { nil }
    notifications.instrument("unrelated.event") { nil }

    assert_includes @io.string, "DCB Append"
    # The default pattern only matches *.dcb, so a non-dcb event is ignored
    # (its humanized label would be "DCB Unrelated.event").
    refute_includes @io.string, "Unrelated.event"
  end

  def test_attach_to_returns_subscription_usable_for_unsubscribe
    notifications = DcbEventStore::Notifications.new
    subscription = DcbEventStore::RailsLogSubscriber.new(logger: @logger).attach_to(notifications)

    notifications.unsubscribe(subscription)
    notifications.instrument("append.dcb") { nil }

    assert_empty @io.string
  end

  def test_attach_to_defaults_to_global_instrumentation
    previous = DcbEventStore.instrumentation
    DcbEventStore.instrumentation = DcbEventStore::Notifications.new
    DcbEventStore::RailsLogSubscriber.new(logger: @logger).attach_to

    DcbEventStore.instrumentation.instrument("read.dcb") { nil }

    assert_includes @io.string, "DCB Read"
  ensure
    DcbEventStore.instrumentation = previous
  end

  def test_custom_pattern
    notifications = DcbEventStore::Notifications.new
    DcbEventStore::RailsLogSubscriber.new(logger: @logger, pattern: "read.dcb").attach_to(notifications)

    notifications.instrument("append.dcb") { nil }
    notifications.instrument("read.dcb") { nil }

    refute_includes @io.string, "DCB Append"
    assert_includes @io.string, "DCB Read"
  end

  # --- default logger (Rails detection) ---

  def with_rails(rails)
    Object.const_set(:Rails, rails)
    yield
  ensure
    Object.send(:remove_const, :Rails)
  end

  def test_defaults_to_rails_logger_when_available
    rails_io = StringIO.new
    rails = Module.new
    rails.define_singleton_method(:logger) { @logger ||= Logger.new(rails_io) }

    with_rails(rails) do
      DcbEventStore::RailsLogSubscriber.new.call(build_event)
    end

    assert_includes rails_io.string, "DCB Append"
  end

  def test_falls_back_to_stdout_when_rails_logger_is_nil
    rails = Module.new
    rails.define_singleton_method(:logger) { nil }

    out = with_rails(rails) do
      capture_stdout { DcbEventStore::RailsLogSubscriber.new.call(build_event) }
    end

    assert_includes out, "DCB Append"
  end

  def test_falls_back_to_stdout_when_rails_has_no_logger
    with_rails(Module.new) do
      out = capture_stdout { DcbEventStore::RailsLogSubscriber.new.call(build_event) }
      assert_includes out, "DCB Append"
    end
  end

  def test_falls_back_to_stdout_when_rails_is_absent
    refute defined?(Rails), "expected no Rails constant in this test environment"

    out = capture_stdout { DcbEventStore::RailsLogSubscriber.new.call(build_event) }

    assert_includes out, "DCB Append"
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end
end
