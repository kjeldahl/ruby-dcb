require_relative "../test_helper"
require_relative "../support/database"

class TestStoreAppend < Minitest::Test
  include DatabaseHelper

  def setup
    setup_db
  end

  def teardown
    teardown_db
  end

  def test_append_without_condition
    event = DcbEventStore::Event.new(type: "A", data: {x: 1}, tags: ["t:1"])
    result = @store.append([event])

    assert_equal 1, result.size
    assert_kind_of DcbEventStore::SequencedEvent, result[0]
    assert_equal "A", result[0].type
    assert_equal({x: 1}, result[0].data)
    assert_equal ["t:1"], result[0].tags
    assert_kind_of Integer, result[0].sequence_position
  end

  def test_append_multiple_events
    events = [
      DcbEventStore::Event.new(type: "A"),
      DcbEventStore::Event.new(type: "B")
    ]
    result = @store.append(events)

    assert_equal 2, result.size
    assert result[0].sequence_position < result[1].sequence_position
  end

  def test_append_condition_passes
    query = DcbEventStore::Query.new([
      DcbEventStore::QueryItem.new(event_types: ["Conflict"])
    ])
    condition = DcbEventStore::AppendCondition.new(fail_if_events_match: query)

    event = DcbEventStore::Event.new(type: "Safe")
    result = @store.append([event], condition)
    assert_equal 1, result.size
  end

  def test_append_condition_fails
    @store.append([DcbEventStore::Event.new(type: "Conflict")])

    query = DcbEventStore::Query.new([
      DcbEventStore::QueryItem.new(event_types: ["Conflict"])
    ])
    condition = DcbEventStore::AppendCondition.new(fail_if_events_match: query)

    assert_raises(DcbEventStore::ConditionNotMet) do
      @store.append([DcbEventStore::Event.new(type: "Another")], condition)
    end
  end

  def test_append_condition_with_after_ignores_earlier
    first = @store.append([DcbEventStore::Event.new(type: "Conflict")])

    query = DcbEventStore::Query.new([
      DcbEventStore::QueryItem.new(event_types: ["Conflict"])
    ])
    condition = DcbEventStore::AppendCondition.new(
      fail_if_events_match: query,
      after: first[0].sequence_position
    )

    # Should pass because the conflicting event is at/before `after`
    result = @store.append([DcbEventStore::Event.new(type: "Safe")], condition)
    assert_equal 1, result.size
  end

  def test_append_condition_nil_after_checks_all
    @store.append([DcbEventStore::Event.new(type: "Conflict")])

    query = DcbEventStore::Query.new([
      DcbEventStore::QueryItem.new(event_types: ["Conflict"])
    ])
    condition = DcbEventStore::AppendCondition.new(fail_if_events_match: query, after: nil)

    assert_raises(DcbEventStore::ConditionNotMet) do
      @store.append([DcbEventStore::Event.new(type: "Another")], condition)
    end
  end

  def test_failed_append_leaves_no_data
    @store.append([DcbEventStore::Event.new(type: "Existing", tags: ["t:1"])])

    query = DcbEventStore::Query.new([
      DcbEventStore::QueryItem.new(event_types: ["Existing"], tags: ["t:1"])
    ])
    condition = DcbEventStore::AppendCondition.new(fail_if_events_match: query)

    begin
      @store.append([DcbEventStore::Event.new(type: "ShouldNotExist")], condition)
    rescue DcbEventStore::ConditionNotMet
      # expected
    end

    all = @store.read(DcbEventStore::Query.all).to_a
    assert_equal 1, all.size
    assert_equal "Existing", all[0].type
  end

  def test_condition_not_met_is_rescuable
    assert DcbEventStore::ConditionNotMet < StandardError
  end
end
