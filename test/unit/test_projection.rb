require_relative "../test_helper"

class TestProjection < Minitest::Test
  def test_fold_no_events_returns_initial
    p = build_counter_projection
    assert_equal 0, p.fold([])
  end

  def test_fold_applies_handler
    p = build_counter_projection
    event = DcbEventStore::SequencedEvent.new(
      sequence_position: 1, type: "Increment", data: {}, tags: [], created_at: Time.now
    )
    assert_equal 1, p.fold([event])
  end

  def test_fold_ignores_unhandled_types
    p = build_counter_projection
    event = DcbEventStore::SequencedEvent.new(
      sequence_position: 1, type: "Other", data: {}, tags: [], created_at: Time.now
    )
    assert_equal 0, p.fold([event])
  end

  def test_fold_multiple_events
    p = build_counter_projection
    events = 3.times.map do |i|
      DcbEventStore::SequencedEvent.new(
        sequence_position: i + 1, type: "Increment", data: {}, tags: [], created_at: Time.now
      )
    end
    assert_equal 3, p.fold(events)
  end

  def test_apply_returns_state_for_unknown_type
    p = build_counter_projection
    event = DcbEventStore::SequencedEvent.new(
      sequence_position: 1, type: "Unknown", data: {}, tags: [], created_at: Time.now
    )
    assert_equal 42, p.apply(42, event)
  end

  def test_event_types
    p = build_counter_projection
    assert_equal ["Increment"], p.event_types
  end

  private

  def build_counter_projection
    DcbEventStore::Projection.new(
      initial_state: 0,
      handlers: {
        "Increment" => ->(state, _event) { state + 1 }
      },
      query: DcbEventStore::Query.new([
        DcbEventStore::QueryItem.new(event_types: ["Increment"])
      ])
    )
  end
end
