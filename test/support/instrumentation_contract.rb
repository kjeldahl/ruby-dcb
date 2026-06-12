# Shared behavioral contract for instrumentation engines.
#
# Every engine assignable to DcbEventStore.instrumentation (Notifications,
# ActiveSupportInstrumentation) must pass these tests with identical
# observable behavior, so emission points and adapters work unchanged
# against either. Including classes must define #build_engine returning a
# fresh engine and call the contract's setup/teardown (subscriptions are
# tracked and removed because some engines publish through global state).
module InstrumentationContract
  def setup
    @engine = build_engine
    @received = []
    @subscriptions = []
  end

  def teardown
    @subscriptions.each { |subscription| @engine.unsubscribe(subscription) }
  end

  def collect(pattern = nil)
    track(@engine.subscribe(pattern) { |event| @received << event })
  end

  def track(subscription)
    @subscriptions << subscription
    subscription
  end

  def test_subscriber_receives_event_with_name_payload_and_timing
    collect("op.dcb")

    result = @engine.instrument("op.dcb", a: 1) { :done }

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

    @engine.instrument("op.dcb") { sleep 0.01 }

    assert_operator @received[0].duration, :>=, 0.01
  end

  def test_instrument_yields_payload_for_enrichment
    collect

    @engine.instrument("op.dcb", a: 1) { |payload| payload[:b] = 2 }

    assert_equal({a: 1, b: 2}, @received[0].payload)
  end

  def test_instrument_default_payload_is_empty_hash
    collect

    @engine.instrument("op.dcb") { nil }

    assert_equal({}, @received[0].payload)
  end

  def test_string_pattern_matches_exact_name_only
    collect("read.dcb")

    @engine.instrument("append.dcb") { nil }
    @engine.instrument("read.dcb") { nil }
    @engine.instrument("read.dcb.extra") { nil }

    assert_equal ["read.dcb"], @received.map(&:name)
  end

  def test_regexp_pattern_filters_by_match
    collect(/\.dcb\z/)

    @engine.instrument("append.dcb") { nil }
    @engine.instrument("other.thing") { nil }

    assert_equal ["append.dcb"], @received.map(&:name)
  end

  def test_nil_pattern_receives_everything
    collect

    @engine.instrument("append.dcb") { nil }
    @engine.instrument("other.thing") { nil }

    assert_equal ["append.dcb", "other.thing"], @received.map(&:name)
  end

  def test_unsubscribe_stops_delivery
    subscription = collect

    @engine.instrument("a.dcb") { nil }
    assert_nil @engine.unsubscribe(subscription)
    @engine.instrument("b.dcb") { nil }

    assert_equal ["a.dcb"], @received.map(&:name)
  end

  def test_subscribe_requires_block
    error = assert_raises(ArgumentError) { @engine.subscribe("op.dcb") }
    assert_equal "a subscriber block is required", error.message
  end

  def test_error_is_captured_published_and_reraised
    collect

    error = assert_raises(RuntimeError) do
      @engine.instrument("op.dcb", a: 1) { raise "boom" }
    end

    assert_equal "boom", error.message
    assert_equal 1, @received.size
    assert_same error, @received[0].error
    assert_equal({a: 1}, @received[0].payload)
    assert_operator @received[0].finished_at, :>=, @received[0].started_at
  end

  def test_listening_reflects_matching_subscribers
    refute @engine.listening?("op.dcb")

    subscription = track(@engine.subscribe("op.dcb") { nil })
    assert @engine.listening?("op.dcb")
    refute @engine.listening?("other.dcb")

    @engine.unsubscribe(subscription)
    refute @engine.listening?("op.dcb")
  end

  def test_without_subscribers_instrument_yields_payload_and_returns_result
    result = @engine.instrument("op.dcb", a: 1) { |payload| payload[:a] + 1 }
    assert_equal 2, result
  end

  def test_without_matching_subscribers_nothing_is_published
    collect("other.dcb")

    @engine.instrument("op.dcb") { nil }

    assert_empty @received
  end

  def test_multiple_subscribers_all_receive
    other = []
    collect
    track(@engine.subscribe { |event| other << event })

    @engine.instrument("op.dcb", a: 1) { nil }

    assert_equal 1, @received.size
    assert_equal 1, other.size
    assert_equal "op.dcb", other[0].name
    assert_equal({a: 1}, other[0].payload)
  end

  def test_works_with_log_subscriber_adapter
    io = StringIO.new
    track(DcbEventStore::LogSubscriber.new(logger: Logger.new(io)).attach_to(@engine))

    @engine.instrument("append.dcb", event_count: 2) { nil }

    assert_includes io.string, "append.dcb"
    assert_includes io.string, "event_count=2"
  end

  def test_works_with_rails_log_subscriber_adapter
    io = StringIO.new
    track(DcbEventStore::RailsLogSubscriber.new(logger: Logger.new(io)).attach_to(@engine))

    @engine.instrument("append.dcb", event_count: 2) { nil }

    assert_includes io.string, "DCB Append"
    assert_includes io.string, "event_count=2"
  end
end
