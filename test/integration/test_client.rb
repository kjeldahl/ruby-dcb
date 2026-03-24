require_relative "../test_helper"
require_relative "../support/database"
require "securerandom"

class TestClientIntegration < Minitest::Test
  cover "DcbEventStore::Client*"

  include DatabaseHelper

  def setup
    setup_db
    @corr_id = SecureRandom.uuid
    @cause_id = SecureRandom.uuid
  end

  def teardown
    teardown_db
  end

  def test_append_and_read_back_with_ids
    ctx = DcbEventStore::Client.new(@store, correlation_id: @corr_id, causation_id: @cause_id)
    query = DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: ["OrderPlaced"])])

    ctx.append(DcbEventStore::Event.new(type: "OrderPlaced", data: { amount: 42 }))

    events = ctx.read(query).to_a
    assert_equal 1, events.size
    assert_equal @corr_id, events.first.correlation_id
    assert_equal @cause_id, events.first.causation_id
  end

  def test_caused_by_chain
    ctx = DcbEventStore::Client.new(@store, correlation_id: @corr_id)
    query = DcbEventStore::Query.all

    result = ctx.append(DcbEventStore::Event.new(type: "OrderPlaced", data: { amount: 42 }))
    event_a = result.first

    child = ctx.caused_by(event_a)
    child.append(DcbEventStore::Event.new(type: "EmailSent", data: { to: "a@b.c" }))

    events = ctx.read(query).to_a
    assert_equal 2, events.size

    b = events.last
    assert_equal "EmailSent", b.type
    assert_equal event_a.id, b.causation_id
    assert_equal @corr_id, b.correlation_id
  end

  def test_works_with_decision_model_conditions
    query = DcbEventStore::Query.new([
                                       DcbEventStore::QueryItem.new(event_types: ["SeatReserved"], tags: ["seat:A1"])
                                     ])

    ctx = DcbEventStore::Client.new(@store, correlation_id: @corr_id)
    ctx.append(DcbEventStore::Event.new(type: "SeatReserved", tags: ["seat:A1"]))

    condition = DcbEventStore::AppendCondition.new(
      fail_if_events_match: query,
      after: 0
    )

    assert_raises(DcbEventStore::ConditionNotMet) do
      ctx.append(DcbEventStore::Event.new(type: "SeatReserved", tags: ["seat:A1"]), condition)
    end
  end
end
