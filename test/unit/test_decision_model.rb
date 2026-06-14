require_relative "../test_helper"

# Behavioral unit tests for DecisionModel against InMemoryStore, so the
# pure filtering/partitioning logic is mutation-tested without a live
# database (integration coverage lives in test/integration/test_decision_model.rb).
class TestDecisionModelUnit < Minitest::Test
  cover "DcbEventStore::DecisionModel*"

  def setup
    @store = DcbEventStore::InMemoryStore.new
  end

  def projection(event_types:, tags:, handlers:)
    DcbEventStore::Projection.new(
      initial_state: 0,
      handlers: handlers,
      query: DcbEventStore::Query.new([
                                        DcbEventStore::QueryItem.new(event_types: event_types, tags: tags)
                                      ])
    )
  end

  def test_specific_event_types_exclude_other_types
    @store.append([
                    DcbEventStore::Event.new(type: "Wanted", tags: ["t:1"]),
                    DcbEventStore::Event.new(type: "Other", tags: ["t:1"])
                  ])

    proj = projection(event_types: ["Wanted"], tags: ["t:1"],
                      handlers: { "Wanted" => ->(s, _e) { s + 1 }, "Other" => ->(s, _e) { s + 100 } })

    result = DcbEventStore::DecisionModel.build(@store, p: proj)
    assert_equal 1, result.states[:p]
  end

  def test_empty_event_types_match_all_types
    @store.append([
                    DcbEventStore::Event.new(type: "A", tags: ["t:1"]),
                    DcbEventStore::Event.new(type: "B", tags: ["t:1"])
                  ])

    proj = projection(event_types: [], tags: ["t:1"],
                      handlers: { "A" => ->(s, _e) { s + 1 }, "B" => ->(s, _e) { s + 1 } })

    result = DcbEventStore::DecisionModel.build(@store, p: proj)
    assert_equal 2, result.states[:p]
  end

  def test_condition_after_is_highest_sequence_position
    appended = @store.append([
                               DcbEventStore::Event.new(type: "A", tags: ["t:1"]),
                               DcbEventStore::Event.new(type: "A", tags: ["t:1"])
                             ])

    proj = projection(event_types: ["A"], tags: ["t:1"], handlers: { "A" => ->(s, _e) { s + 1 } })
    result = DcbEventStore::DecisionModel.build(@store, p: proj)

    assert_equal appended.last.sequence_position, result.append_condition.after
  end

  def test_condition_after_is_nil_on_empty_store
    proj = projection(event_types: ["A"], tags: ["t:1"], handlers: { "A" => ->(s, _e) { s + 1 } })
    result = DcbEventStore::DecisionModel.build(@store, p: proj)

    assert_nil result.append_condition.after
  end
end
