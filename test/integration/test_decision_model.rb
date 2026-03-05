require_relative "../test_helper"
require_relative "../support/database"

class TestDecisionModel < Minitest::Test
  include DatabaseHelper

  def setup
    setup_db
  end

  def teardown
    teardown_db
  end

  def test_single_projection
    @store.append([DcbEventStore::Event.new(type: "Increment", tags: ["counter:a"])])

    result = DcbEventStore::DecisionModel.build(@store,
      count: counter_projection("counter:a")
    )

    assert_equal 1, result.states[:count]
  end

  def test_multiple_projections
    @store.append([
      DcbEventStore::Event.new(type: "CourseDefined", data: {capacity: 5}, tags: ["course:c1"]),
      DcbEventStore::Event.new(type: "StudentSubscribed", tags: ["course:c1", "student:s1"])
    ])

    result = DcbEventStore::DecisionModel.build(@store,
      capacity: capacity_projection("course:c1"),
      subscriptions: subscription_count_projection("course:c1")
    )

    assert_equal 5, result.states[:capacity]
    assert_equal 1, result.states[:subscriptions]
  end

  def test_condition_after_equals_max_position
    events = @store.append([
      DcbEventStore::Event.new(type: "Increment", tags: ["counter:a"]),
      DcbEventStore::Event.new(type: "Increment", tags: ["counter:a"])
    ])

    result = DcbEventStore::DecisionModel.build(@store,
      count: counter_projection("counter:a")
    )

    assert_equal events.last.sequence_position, result.append_condition.after
  end

  def test_condition_after_nil_on_empty_store
    result = DcbEventStore::DecisionModel.build(@store,
      count: counter_projection("counter:a")
    )

    assert_nil result.append_condition.after
    assert_equal 0, result.states[:count]
  end

  def test_end_to_end_course_subscription
    # Define course with capacity 2
    @store.append([
      DcbEventStore::Event.new(type: "CourseDefined", data: {capacity: 2}, tags: ["course:c1"])
    ])

    # First student subscribes
    result = DcbEventStore::DecisionModel.build(@store,
      capacity: capacity_projection("course:c1"),
      subscriptions: subscription_count_projection("course:c1")
    )
    assert_equal 2, result.states[:capacity]
    assert_equal 0, result.states[:subscriptions]

    @store.append(
      [DcbEventStore::Event.new(type: "StudentSubscribed", tags: ["course:c1", "student:s1"])],
      result.append_condition
    )

    # Second student subscribes
    result = DcbEventStore::DecisionModel.build(@store,
      capacity: capacity_projection("course:c1"),
      subscriptions: subscription_count_projection("course:c1")
    )
    assert_equal 1, result.states[:subscriptions]

    @store.append(
      [DcbEventStore::Event.new(type: "StudentSubscribed", tags: ["course:c1", "student:s2"])],
      result.append_condition
    )

    # Third student should fail based on stale condition
    stale_result = result
    assert_raises(DcbEventStore::ConditionNotMet) do
      @store.append(
        [DcbEventStore::Event.new(type: "StudentSubscribed", tags: ["course:c1", "student:s3"])],
        stale_result.append_condition
      )
    end
  end

  private

  def counter_projection(tag)
    DcbEventStore::Projection.new(
      initial_state: 0,
      handlers: { "Increment" => ->(state, _e) { state + 1 } },
      query: DcbEventStore::Query.new([
        DcbEventStore::QueryItem.new(event_types: ["Increment"], tags: [tag])
      ])
    )
  end

  def capacity_projection(course_tag)
    DcbEventStore::Projection.new(
      initial_state: 0,
      handlers: {
        "CourseDefined" => ->(_, e) { e.data[:capacity] }
      },
      query: DcbEventStore::Query.new([
        DcbEventStore::QueryItem.new(event_types: ["CourseDefined"], tags: [course_tag])
      ])
    )
  end

  def subscription_count_projection(course_tag)
    DcbEventStore::Projection.new(
      initial_state: 0,
      handlers: {
        "StudentSubscribed" => ->(state, _e) { state + 1 }
      },
      query: DcbEventStore::Query.new([
        DcbEventStore::QueryItem.new(event_types: ["StudentSubscribed"], tags: [course_tag])
      ])
    )
  end
end
