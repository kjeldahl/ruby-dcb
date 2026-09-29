require_relative "../test_helper"

# DecisionModel.decide and Client#decide against InMemoryStore: the retry
# loop, backoff and instrumentation (issue #52). The backends run the same
# loop through DecisionModelContract; the real race is in
# test/concurrency/test_concurrent_decide.rb.
module DecideFixtures
  def subscriptions
    DcbEventStore::Projection.new(
      initial_state: 0,
      handlers: { "Subscribed" => ->(count, _event) { count + 1 } },
      query: DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: ["Subscribed"],
                                                                    tags: ["course:c1"])])
    )
  end

  def subscribed_event = DcbEventStore::Event.new(type: "Subscribed", tags: ["course:c1"])
end

class TestDecide < Minitest::Test
  cover "DcbEventStore::DecisionModel*"
  cover "DcbEventStore::Client*"

  include DecideFixtures

  Event = DcbEventStore::Event

  # An InMemoryStore where another writer gets in first: before each of the
  # first +races+ appends it commits one "Subscribed" event on the course,
  # which the append's condition then trips over.
  class RacingStore < DcbEventStore::InMemoryStore
    attr_reader :append_calls

    def initialize(races:)
      super()
      @races = races
      @append_calls = 0
    end

    def append(events, condition = nil)
      @append_calls += 1
      if @races.positive?
        @races -= 1
        super([Event.new(type: "Subscribed", tags: ["course:c1"], data: {by: "rival"})])
      end
      super
    end
  end

  class Full < StandardError; end

  def setup
    @store = DcbEventStore::InMemoryStore.new
    @sleeps = []
    @sleeper = ->(seconds) { @sleeps << seconds }
  end

  def subscribe(store = @store, **, &)
    DcbEventStore::DecisionModel.decide(store, sleeper: @sleeper, subscriptions: subscriptions, **, &)
  end

  def test_appends_what_the_block_returns_and_returns_the_stored_events
    seen = []
    appended = subscribe do |states|
      seen << states
      [subscribed_event]
    end

    assert_equal [{ subscriptions: 0 }], seen
    assert_equal 1, appended.size
    assert_kind_of DcbEventStore::SequencedEvent, appended.first
    assert_equal appended, @store.read(DcbEventStore::Query.all).to_a
    assert_empty @sleeps
  end

  def test_a_single_event_needs_no_array
    appended = subscribe { subscribed_event }

    assert_equal ["Subscribed"], appended.map(&:type)
  end

  def test_empty_or_nil_appends_nothing
    assert_equal([], subscribe { [] })
    assert_equal([], subscribe { nil })
    assert_empty @store.read(DcbEventStore::Query.all).to_a
  end

  def test_the_append_carries_the_models_condition
    @store.append([subscribed_event])
    conditions = []
    @store.define_singleton_method(:append) do |events, condition = nil|
      conditions << condition
      super(events, condition)
    end

    subscribe { [subscribed_event] }

    condition = conditions.first
    assert_equal 1, condition.after
    assert_equal subscriptions.query, condition.fail_if_events_match
  end

  def test_retries_a_conflict_from_a_fresh_build
    store = RacingStore.new(races: 2)
    seen = []

    appended = subscribe(store) do |states|
      seen << states[:subscriptions]
      [Event.new(type: "Subscribed", tags: ["course:c1"], data: {by: "me"})]
    end

    assert_equal [0, 1, 2], seen
    assert_equal 3, store.append_calls
    assert_equal [{ by: "me" }], appended.map(&:data)
    assert_equal 3, store.read(DcbEventStore::Query.all).count
  end

  # The decision is taken again on the fresh state, so a rule the rival's
  # event now breaks is enforced.
  def test_the_retry_can_decide_differently
    store = RacingStore.new(races: 1)

    assert_raises(Full) do
      subscribe(store) do |states|
        raise Full if states[:subscriptions] >= 1

        [subscribed_event]
      end
    end
    assert_equal 1, store.append_calls
  end

  def test_out_of_retries_reraises_the_last_conflict
    store = RacingStore.new(races: 3)
    calls = 0

    assert_raises(DcbEventStore::ConditionNotMet) do
      subscribe(store, retries: 2) do
        calls += 1
        [subscribed_event]
      end
    end
    assert_equal 3, calls
    assert_equal 2, @sleeps.size
  end

  def test_retries_exactly_up_to_the_limit
    store = RacingStore.new(races: 2)

    appended = subscribe(store, retries: 2) { [subscribed_event] }

    assert_equal 1, appended.size
    assert_equal 3, store.append_calls
  end

  def test_three_retries_by_default
    store = RacingStore.new(races: 3)
    appended = subscribe(store) { [subscribed_event] }
    assert_equal 1, appended.size
    assert_equal DcbEventStore::DecisionModel::DEFAULT_RETRIES, @sleeps.size

    store = RacingStore.new(races: 4)
    assert_raises(DcbEventStore::ConditionNotMet) { subscribe(store) { [subscribed_event] } }
  end

  def test_zero_retries_raises_the_first_conflict
    store = RacingStore.new(races: 1)

    assert_raises(DcbEventStore::ConditionNotMet) { subscribe(store, retries: 0) { [subscribed_event] } }
    assert_equal 1, store.append_calls
    assert_empty @sleeps
  end

  def test_other_errors_are_not_retried
    calls = 0
    assert_raises(Full) do
      subscribe do
        calls += 1
        raise Full
      end
    end
    assert_equal 1, calls

    failing = DcbEventStore::InMemoryStore.new
    failing.define_singleton_method(:append) { |*| raise IOError, "down" }
    assert_raises(IOError) { subscribe(failing) { [subscribed_event] } }
    assert_empty @sleeps
  end

  # Only the append's conflict is retried; the same error raised by the
  # decision itself is its own.
  def test_a_conflict_raised_by_the_block_is_not_retried
    calls = 0
    assert_raises(DcbEventStore::ConditionNotMet) do
      subscribe do
        calls += 1
        raise DcbEventStore::ConditionNotMet, "mine"
      end
    end
    assert_equal 1, calls
  end

  def test_default_backoff_is_jittered_within_its_range
    store = RacingStore.new(races: 3)

    subscribe(store) { [subscribed_event] }

    assert_equal 3, @sleeps.size
    assert(@sleeps.all? { |s| DcbEventStore::DecisionModel::DEFAULT_BACKOFF.cover?(s) }, @sleeps.inspect)
    assert_equal 0.01..0.2, DcbEventStore::DecisionModel::DEFAULT_BACKOFF
  end

  def test_range_backoff_draws_from_the_range
    store = RacingStore.new(races: 20)

    subscribe(store, retries: 20, backoff: 1.0..2.0) { [subscribed_event] }

    assert(@sleeps.all? { |s| (1.0..2.0).cover?(s) }, @sleeps.inspect)
    assert_operator @sleeps.uniq.size, :>, 1
  end

  def test_numeric_backoff_is_fixed
    subscribe(RacingStore.new(races: 2), backoff: 0.5) { [subscribed_event] }

    assert_equal [0.5, 0.5], @sleeps
  end

  def test_callable_backoff_gets_the_failed_attempt
    subscribe(RacingStore.new(races: 3), backoff: ->(attempt) { attempt * 0.1 }) { [subscribed_event] }

    assert_equal [0.1, 0.2, 0.30000000000000004], @sleeps
  end

  def test_no_pause_for_nil_or_zero_backoff
    subscribe(RacingStore.new(races: 1), backoff: nil) { [subscribed_event] }
    subscribe(RacingStore.new(races: 1), backoff: 0) { [subscribed_event] }
    subscribe(RacingStore.new(races: 1), backoff: ->(_) { 0 }) { [subscribed_event] }

    assert_empty @sleeps
  end

  def test_sleeps_with_kernel_sleep_by_default
    store = RacingStore.new(races: 1)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    DcbEventStore::DecisionModel.decide(store, backoff: 0.05, subscriptions: subscriptions) { [subscribed_event] }

    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :>=, 0.05
  end

  def test_requires_a_block
    error = assert_raises(ArgumentError) { subscribe }
    assert_equal "a decision block is required", error.message
  end

  def test_rejects_invalid_retries
    [-1, 1.5, nil, "3"].each do |retries|
      error = assert_raises(ArgumentError) { subscribe(retries: retries) { [] } }
      assert_equal "retries must be a non-negative Integer, got #{retries.inspect}", error.message
    end
  end

  def test_rejects_invalid_backoff
    error = assert_raises(ArgumentError) { subscribe(backoff: "0.1") { [] } }
    assert_equal 'backoff must be a Range, a Numeric, a callable or nil, got "0.1"', error.message
  end

  def test_validates_before_building
    @store.define_singleton_method(:read) { |*| flunk "built" }

    assert_raises(ArgumentError) { subscribe(retries: -1) { [] } }
    assert_raises(ArgumentError) { subscribe(backoff: :x) { [] } }
  end

  def test_passes_snapshots_through
    snapshots = DcbEventStore::Snapshots::InMemorySnapshotStore.new
    projection = DcbEventStore::Projection.new(
      initial_state: 0,
      handlers: { "Subscribed" => ->(count, _event) { count + 1 } },
      query: subscriptions.query,
      snapshot: DcbEventStore::Snapshot.new(name: "subs", version: 1, every: 1)
    )
    @store.append([subscribed_event])

    DcbEventStore::DecisionModel.decide(@store, snapshots: snapshots, subs: projection) { [] }

    assert_equal 1, snapshots.fetch(projection.snapshot.key(projection.query)).state
  end

  def test_without_projections_decides_on_the_whole_log
    @store.append([Event.new(type: "Other")])
    seen = nil

    DcbEventStore::DecisionModel.decide(@store) do |states|
      seen = states
      []
    end

    assert_equal({}, seen)
  end

  # --- Client#decide ---

  def test_client_decide_stamps_the_events
    client = DcbEventStore::Client.new(RacingStore.new(races: 1), correlation_id: "corr", causation_id: "cause")
    seen = []

    appended = client.decide(sleeper: @sleeper, subscriptions: subscriptions) do |states|
      seen << states[:subscriptions]
      subscribed_event
    end

    assert_equal [0, 1], seen
    assert_equal([%w[corr cause]], appended.map { |e| [e.correlation_id, e.causation_id] })
    assert_equal 1, @sleeps.size
  end

  def test_client_decide_passes_options_through
    store = RacingStore.new(races: 1)
    client = DcbEventStore::Client.new(store)

    assert_raises(DcbEventStore::ConditionNotMet) do
      client.decide(retries: 0, subscriptions: subscriptions) { subscribed_event }
    end
  end

  def test_client_decide_with_nothing_to_append
    client = DcbEventStore::Client.new(@store)

    assert_equal [], client.decide(subscriptions: subscriptions) { nil }
  end

  def test_client_decide_requires_a_block
    error = assert_raises(ArgumentError) { DcbEventStore::Client.new(@store).decide(subscriptions: subscriptions) }
    assert_equal "a decision block is required", error.message
  end
end

class TestDecideInstrumentation < Minitest::Test
  cover "DcbEventStore::DecisionModel*"

  def setup
    @events = []
    @previous_instrumentation = DcbEventStore.instrumentation
    DcbEventStore.instrumentation = DcbEventStore::Notifications.new
    DcbEventStore.instrumentation.subscribe(/\A(decide|decision_model)\.dcb\z/) { |event| @events << event }
  end

  def teardown
    DcbEventStore.instrumentation = @previous_instrumentation
  end

  include DecideFixtures

  def test_publishes_decide_with_attempts_and_each_build_with_its_attempt
    store = TestDecide::RacingStore.new(races: 2)

    DcbEventStore::DecisionModel.decide(store, backoff: nil, subscriptions: subscriptions) { [subscribed_event] }

    assert_equal %w[decision_model.dcb decision_model.dcb decision_model.dcb decide.dcb], @events.map(&:name)
    assert_equal([1, 2, 3], @events.first(3).map { |e| e.payload[:attempt] })
    assert_equal({ projections: [:subscriptions], attempts: 3, appended_count: 1 }, @events.last.payload)
    assert_nil @events.last.error
  end

  def test_the_attempt_follows_the_projection_names
    DcbEventStore::DecisionModel.decide(DcbEventStore::InMemoryStore.new, subscriptions: subscriptions) { [] }

    assert_equal %i[projections attempt], @events.first.payload.keys.first(2)
  end

  def test_nothing_appended_counts_zero
    DcbEventStore::DecisionModel.decide(DcbEventStore::InMemoryStore.new, subscriptions: subscriptions) { [] }

    assert_equal({ projections: [:subscriptions], attempts: 1, appended_count: 0 }, @events.last.payload)
  end

  def test_out_of_retries_publishes_the_error_and_the_attempts
    store = TestDecide::RacingStore.new(races: 2)

    assert_raises(DcbEventStore::ConditionNotMet) do
      DcbEventStore::DecisionModel.decide(store, retries: 1, backoff: nil, subscriptions: subscriptions) do
        [subscribed_event]
      end
    end

    decide = @events.last
    assert_equal "decide.dcb", decide.name
    assert_kind_of DcbEventStore::ConditionNotMet, decide.error
    assert_equal({ projections: [:subscriptions], attempts: 2 }, decide.payload)
  end

  def test_a_plain_build_carries_no_attempt
    DcbEventStore::DecisionModel.build(DcbEventStore::InMemoryStore.new, subscriptions: subscriptions)

    refute @events.first.payload.key?(:attempt)
  end
end
