require_relative "../test_helper"
require_relative "../support/database"

class TestDecisionModel < Minitest::Test
  cover "DcbEventStore::DecisionModel*"

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
                                                count: counter_projection("counter:a"))

    assert_equal 1, result.states[:count]
  end

  def test_multiple_projections
    @store.append([
                    DcbEventStore::Event.new(type: "CourseDefined", data: {capacity: 5}, tags: ["course:c1"]),
                    DcbEventStore::Event.new(type: "StudentSubscribed", tags: ["course:c1", "student:s1"])
                  ])

    result = DcbEventStore::DecisionModel.build(@store,
                                                capacity: capacity_projection("course:c1"),
                                                subscriptions: subscription_count_projection("course:c1"))

    assert_equal 5, result.states[:capacity]
    assert_equal 1, result.states[:subscriptions]
  end

  def test_condition_after_equals_max_position
    events = @store.append([
                             DcbEventStore::Event.new(type: "Increment", tags: ["counter:a"]),
                             DcbEventStore::Event.new(type: "Increment", tags: ["counter:a"])
                           ])

    result = DcbEventStore::DecisionModel.build(@store,
                                                count: counter_projection("counter:a"))

    assert_equal events.last.sequence_position, result.append_condition.after
  end

  def test_condition_after_nil_on_empty_store
    result = DcbEventStore::DecisionModel.build(@store,
                                                count: counter_projection("counter:a"))

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
                                                subscriptions: subscription_count_projection("course:c1"))
    assert_equal 2, result.states[:capacity]
    assert_equal 0, result.states[:subscriptions]

    @store.append(
      [DcbEventStore::Event.new(type: "StudentSubscribed", tags: ["course:c1", "student:s1"])],
      result.append_condition
    )

    # Second student subscribes
    result = DcbEventStore::DecisionModel.build(@store,
                                                capacity: capacity_projection("course:c1"),
                                                subscriptions: subscription_count_projection("course:c1"))
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

  def test_filters_by_tag
    @store.append([
                    DcbEventStore::Event.new(type: "Increment", tags: ["counter:a"]),
                    DcbEventStore::Event.new(type: "Increment", tags: ["counter:b"]),
                    DcbEventStore::Event.new(type: "Increment", tags: ["counter:a"])
                  ])

    result = DcbEventStore::DecisionModel.build(@store,
                                                count: counter_projection("counter:a"))

    assert_equal 2, result.states[:count]
  end

  def test_matches_projection_filters_by_type
    both_handler = { "X" => ->(s, _e) { s + 1 }, "Y" => ->(s, _e) { s + 1 } }

    proj_x = DcbEventStore::Projection.new(
      initial_state: 0, handlers: both_handler,
      query: DcbEventStore::Query.new([
                                        DcbEventStore::QueryItem.new(event_types: ["X"], tags: ["t:1"])
                                      ])
    )
    proj_y = DcbEventStore::Projection.new(
      initial_state: 0, handlers: both_handler,
      query: DcbEventStore::Query.new([
                                        DcbEventStore::QueryItem.new(event_types: ["Y"], tags: ["t:1"])
                                      ])
    )

    @store.append([
                    DcbEventStore::Event.new(type: "X", tags: ["t:1"]),
                    DcbEventStore::Event.new(type: "Y", tags: ["t:1"])
                  ])

    result = DcbEventStore::DecisionModel.build(@store, x: proj_x, y: proj_y)
    assert_equal 1, result.states[:x]
    assert_equal 1, result.states[:y]
  end

  def test_filters_by_type_and_tag_combined
    make_proj = ->(tag) {
      DcbEventStore::Projection.new(
        initial_state: 0,
        handlers: { "Evt" => ->(s, _e) { s + 1 } },
        query: DcbEventStore::Query.new([
                                          DcbEventStore::QueryItem.new(event_types: ["Evt"], tags: [tag])
                                        ])
      )
    }

    @store.append([
                    DcbEventStore::Event.new(type: "Evt", tags: ["x:a"]),
                    DcbEventStore::Event.new(type: "Evt", tags: ["x:b"]),
                    DcbEventStore::Event.new(type: "Evt", tags: ["x:a", "x:b"]),
                    DcbEventStore::Event.new(type: "Other", tags: ["x:a"])
                  ])

    result = DcbEventStore::DecisionModel.build(@store,
                                                a: make_proj.call("x:a"),
                                                b: make_proj.call("x:b"))

    assert_equal 2, result.states[:a]
    assert_equal 2, result.states[:b]
  end

  def test_combined_query_includes_all_projection_items
    @store.append([
                    DcbEventStore::Event.new(type: "Increment", tags: ["counter:a"]),
                    DcbEventStore::Event.new(type: "Increment", tags: ["counter:b"])
                  ])

    result = DcbEventStore::DecisionModel.build(@store,
                                                a: counter_projection("counter:a"),
                                                b: counter_projection("counter:b"))

    assert_equal 1, result.states[:a]
    assert_equal 1, result.states[:b]
    assert_equal 2, result.append_condition.after
  end

  def test_condition_query_matches_projection_queries
    @store.append([DcbEventStore::Event.new(type: "Increment", tags: ["counter:a"])])

    result = DcbEventStore::DecisionModel.build(@store,
                                                count: counter_projection("counter:a"))

    refute result.append_condition.fail_if_events_match.match_all?
  end

  def test_multi_item_query_projection
    proj = DcbEventStore::Projection.new(
      initial_state: 0,
      handlers: { "A" => ->(s, _e) { s + 1 }, "B" => ->(s, _e) { s + 10 } },
      query: DcbEventStore::Query.new([
                                        DcbEventStore::QueryItem.new(event_types: ["A"], tags: ["x:1"]),
                                        DcbEventStore::QueryItem.new(event_types: ["B"], tags: ["x:1"])
                                      ])
    )

    @store.append([
                    DcbEventStore::Event.new(type: "A", tags: ["x:1"]),
                    DcbEventStore::Event.new(type: "B", tags: ["x:1"]),
                    DcbEventStore::Event.new(type: "C", tags: ["x:1"])
                  ])

    result = DcbEventStore::DecisionModel.build(@store, total: proj)
    assert_equal 11, result.states[:total]
  end

  def test_wildcard_event_types_matches_all_types
    wildcard_proj = DcbEventStore::Projection.new(
      initial_state: 0,
      handlers: { "A" => ->(s, _e) { s + 1 }, "B" => ->(s, _e) { s + 1 } },
      query: DcbEventStore::Query.new([
                                        DcbEventStore::QueryItem.new(event_types: [], tags: ["x:1"])
                                      ])
    )
    specific_proj = DcbEventStore::Projection.new(
      initial_state: 0,
      handlers: { "A" => ->(s, _e) { s + 1 } },
      query: DcbEventStore::Query.new([
                                        DcbEventStore::QueryItem.new(event_types: ["A"], tags: ["x:1"])
                                      ])
    )

    @store.append([
                    DcbEventStore::Event.new(type: "A", tags: ["x:1"]),
                    DcbEventStore::Event.new(type: "B", tags: ["x:1"])
                  ])

    result = DcbEventStore::DecisionModel.build(@store,
                                                wild: wildcard_proj,
                                                specific: specific_proj)
    assert_equal 2, result.states[:wild]
    assert_equal 1, result.states[:specific]
  end

  def test_matches_projection_filters_by_tags
    handler = { "Evt" => ->(s, _e) { s + 1 } }

    proj_ab = DcbEventStore::Projection.new(
      initial_state: 0, handlers: handler,
      query: DcbEventStore::Query.new([
                                        DcbEventStore::QueryItem.new(event_types: ["Evt"], tags: ["a:1", "b:2"])
                                      ])
    )
    proj_a = DcbEventStore::Projection.new(
      initial_state: 0, handlers: handler,
      query: DcbEventStore::Query.new([
                                        DcbEventStore::QueryItem.new(event_types: ["Evt"], tags: ["a:1"])
                                      ])
    )

    @store.append([
                    DcbEventStore::Event.new(type: "Evt", tags: ["a:1", "b:2", "c:3"]),
                    DcbEventStore::Event.new(type: "Evt", tags: ["a:1"]),
                    DcbEventStore::Event.new(type: "Evt", tags: ["a:1", "b:2"])
                  ])

    result = DcbEventStore::DecisionModel.build(@store, ab: proj_ab, a: proj_a)
    assert_equal 2, result.states[:ab]
    assert_equal 3, result.states[:a]
  end

  def test_wildcard_tags_matches_all_tags
    wildcard_tags_proj = DcbEventStore::Projection.new(
      initial_state: 0,
      handlers: { "Evt" => ->(s, _e) { s + 1 } },
      query: DcbEventStore::Query.new([
                                        DcbEventStore::QueryItem.new(event_types: ["Evt"], tags: [])
                                      ])
    )
    tagged_proj = DcbEventStore::Projection.new(
      initial_state: 0,
      handlers: { "Evt" => ->(s, _e) { s + 1 } },
      query: DcbEventStore::Query.new([
                                        DcbEventStore::QueryItem.new(event_types: ["Evt"], tags: ["a:1"])
                                      ])
    )

    @store.append([
                    DcbEventStore::Event.new(type: "Evt", tags: ["a:1"]),
                    DcbEventStore::Event.new(type: "Evt", tags: ["b:2"])
                  ])

    result = DcbEventStore::DecisionModel.build(@store,
                                                all: wildcard_tags_proj,
                                                tagged: tagged_proj)
    assert_equal 2, result.states[:all]
    assert_equal 1, result.states[:tagged]
  end

  private

  def build_projection(type, tag, initial: 0, &handler)
    handler ||= ->(s, _e) { s + 1 }
    qi = DcbEventStore::QueryItem.new(event_types: [type], tags: [tag])
    DcbEventStore::Projection.new(initial_state: initial, handlers: { type => handler },
                                  query: DcbEventStore::Query.new([qi]))
  end

  def counter_projection(tag) = build_projection("Increment", tag)
  def capacity_projection(tag) = build_projection("CourseDefined", tag) { |_, e| e.data[:capacity] }
  def subscription_count_projection(tag) = build_projection("StudentSubscribed", tag)
end
