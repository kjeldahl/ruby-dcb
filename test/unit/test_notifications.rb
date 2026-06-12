require_relative "../test_helper"

class TestNotifications < Minitest::Test
  cover "DcbEventStore::Notifications*"

  def setup
    @notifications = DcbEventStore::Notifications.new
    @received = []
  end

  def collect(pattern = nil)
    @notifications.subscribe(pattern) { |event| @received << event }
  end

  def test_subscriber_receives_event_with_name_payload_and_timing
    collect("op.dcb")

    result = @notifications.instrument("op.dcb", a: 1) { :done }

    assert_equal :done, result
    assert_equal 1, @received.size
    event = @received[0]
    assert_equal "op.dcb", event.name
    assert_equal({a: 1}, event.payload)
    assert_nil event.error
    assert_operator event.finished_at, :>=, event.started_at
    assert_in_delta event.finished_at - event.started_at, event.duration
  end

  def test_duration_reflects_elapsed_time
    collect

    @notifications.instrument("op.dcb") { sleep 0.01 }

    assert_operator @received[0].duration, :>=, 0.01
  end

  def test_instrument_yields_payload_for_enrichment
    collect

    @notifications.instrument("op.dcb", a: 1) { |payload| payload[:b] = 2 }

    assert_equal({a: 1, b: 2}, @received[0].payload)
  end

  def test_instrument_default_payload_is_empty_hash
    collect

    @notifications.instrument("op.dcb") { nil }

    assert_equal({}, @received[0].payload)
  end

  def test_string_pattern_matches_exact_name_only
    collect("read.dcb")

    @notifications.instrument("append.dcb") { nil }
    @notifications.instrument("read.dcb") { nil }
    @notifications.instrument("read.dcb.extra") { nil }

    assert_equal ["read.dcb"], @received.map(&:name)
  end

  def test_regexp_pattern_filters_by_match
    collect(/\.dcb\z/)

    @notifications.instrument("append.dcb") { nil }
    @notifications.instrument("other.thing") { nil }

    assert_equal ["append.dcb"], @received.map(&:name)
  end

  def test_nil_pattern_receives_everything
    collect

    @notifications.instrument("append.dcb") { nil }
    @notifications.instrument("other.thing") { nil }

    assert_equal ["append.dcb", "other.thing"], @received.map(&:name)
  end

  def test_unsubscribe_stops_delivery
    subscription = collect

    @notifications.instrument("a.dcb") { nil }
    assert_nil @notifications.unsubscribe(subscription)
    @notifications.instrument("b.dcb") { nil }

    assert_equal ["a.dcb"], @received.map(&:name)
  end

  def test_subscribe_requires_block
    error = assert_raises(ArgumentError) { @notifications.subscribe("op.dcb") }
    assert_equal "a subscriber block is required", error.message
  end

  def test_error_is_captured_published_and_reraised
    collect

    error = assert_raises(RuntimeError) do
      @notifications.instrument("op.dcb", a: 1) { raise "boom" }
    end

    assert_equal "boom", error.message
    assert_equal 1, @received.size
    assert_same error, @received[0].error
    assert_equal({a: 1}, @received[0].payload)
    assert_operator @received[0].finished_at, :>=, @received[0].started_at
  end

  def test_listening_reflects_matching_subscribers
    refute @notifications.listening?("op.dcb")

    subscription = @notifications.subscribe("op.dcb") { nil }
    assert @notifications.listening?("op.dcb")
    refute @notifications.listening?("other.dcb")

    @notifications.unsubscribe(subscription)
    refute @notifications.listening?("op.dcb")
  end

  def test_without_subscribers_instrument_yields_payload_and_returns_result
    result = @notifications.instrument("op.dcb", a: 1) { |payload| payload[:a] + 1 }
    assert_equal 2, result
  end

  def test_without_matching_subscribers_nothing_is_published
    collect("other.dcb")

    @notifications.instrument("op.dcb") { nil }

    assert_empty @received
  end

  def test_multiple_subscribers_all_receive_the_same_event
    other = []
    collect
    @notifications.subscribe { |event| other << event }

    @notifications.instrument("op.dcb") { nil }

    assert_equal 1, @received.size
    assert_equal 1, other.size
    assert_same @received[0], other[0]
  end
end
