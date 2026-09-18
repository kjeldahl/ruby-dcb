require "securerandom"

# Shared behavioral contract for Client on top of a real store: correlation
# and causation ids must survive the append/read round trip, and conditions
# must be passed through to the store.
#
# Including classes must set @store in setup.
module ClientContract
  def test_client_append_and_read_back_with_ids
    corr_id = SecureRandom.uuid
    cause_id = SecureRandom.uuid
    client = DcbEventStore::Client.new(@store, correlation_id: corr_id, causation_id: cause_id)
    query = DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: ["OrderPlaced"])])

    client.append(DcbEventStore::Event.new(type: "OrderPlaced", data: {amount: 42}))

    events = client.read(query).to_a
    assert_equal 1, events.size
    assert_equal corr_id, events.first.correlation_id
    assert_equal cause_id, events.first.causation_id
  end

  def test_client_generates_correlation_id_when_not_supplied
    client = DcbEventStore::Client.new(@store)

    client.append(DcbEventStore::Event.new(type: "OrderPlaced"))

    events = client.read(DcbEventStore::Query.all).to_a
    assert_equal 1, events.size
    assert_equal client.correlation_id, events[0].correlation_id
  end

  def test_client_caused_by_chain
    corr_id = SecureRandom.uuid
    client = DcbEventStore::Client.new(@store, correlation_id: corr_id)

    result = client.append(DcbEventStore::Event.new(type: "OrderPlaced", data: {amount: 42}))
    event_a = result.first

    child = client.caused_by(event_a)
    child.append(DcbEventStore::Event.new(type: "EmailSent", data: {to: "a@b.c"}))

    events = client.read(DcbEventStore::Query.all).to_a
    assert_equal 2, events.size

    event_b = events.last
    assert_equal "EmailSent", event_b.type
    assert_equal event_a.id, event_b.causation_id
    assert_equal corr_id, event_b.correlation_id
  end

  def test_client_read_from_skips_earlier_events
    client = DcbEventStore::Client.new(@store)
    first = client.append(DcbEventStore::Event.new(type: "OrderPlaced"))
    client.append(DcbEventStore::Event.new(type: "OrderShipped"))

    events = client.read_from(DcbEventStore::Query.all,
                              after: first.first.sequence_position).to_a
    assert_equal ["OrderShipped"], events.map(&:type)
  end

  def test_client_passes_append_condition_to_store
    query = DcbEventStore::Query.new([
                                       DcbEventStore::QueryItem.new(event_types: ["SeatReserved"], tags: ["seat:A1"])
                                     ])

    client = DcbEventStore::Client.new(@store)
    client.append(DcbEventStore::Event.new(type: "SeatReserved", tags: ["seat:A1"]))

    condition = DcbEventStore::AppendCondition.new(fail_if_events_match: query, after: 0)

    assert_raises(DcbEventStore::ConditionNotMet) do
      client.append(DcbEventStore::Event.new(type: "SeatReserved", tags: ["seat:A1"]), condition)
    end
  end
end
