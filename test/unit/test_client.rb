require_relative "../test_helper"

class TestClient < Minitest::Test
  cover "DcbEventStore::Client*"

  FakeStore = Struct.new(:appended) do
    def initialize
      super([])
    end

    def append(events, condition = nil)
      appended << { events: events, condition: condition }
      events
    end

    def read(query) = [:read, query]
    def read_from(query, after:) = [:read_from, query, after]
  end

  def test_stamps_correlation_and_causation_ids
    store = FakeStore.new
    ctx = DcbEventStore::Client.new(store, correlation_id: "corr-1", causation_id: "cause-1")

    ctx.append(DcbEventStore::Event.new(type: "Foo"))

    stamped = store.appended.first[:events].first
    assert_equal "corr-1", stamped.correlation_id
    assert_equal "cause-1", stamped.causation_id
  end

  def test_explicit_event_ids_not_overwritten
    store = FakeStore.new
    ctx = DcbEventStore::Client.new(store, correlation_id: "corr-1", causation_id: "cause-1")

    event = DcbEventStore::Event.new(type: "Foo", causation_id: "my-cause", correlation_id: "my-corr")
    ctx.append(event)

    stamped = store.appended.first[:events].first
    assert_equal "my-corr", stamped.correlation_id
    assert_equal "my-cause", stamped.causation_id
  end

  def test_caused_by_returns_child_context
    store = FakeStore.new
    ctx = DcbEventStore::Client.new(store, correlation_id: "corr-1")

    event = DcbEventStore::SequencedEvent.new(
      sequence_position: 1, type: "Foo", data: {}, tags: [],
      created_at: Time.now, id: "evt-1", causation_id: nil,
      correlation_id: "corr-1", schema_version: 1
    )

    child = ctx.caused_by(event)
    assert_equal "evt-1", child.causation_id
    assert_equal "corr-1", child.correlation_id
  end

  def test_caused_by_uses_event_correlation_id_if_present
    store = FakeStore.new
    ctx = DcbEventStore::Client.new(store, correlation_id: "ctx-corr")

    event = DcbEventStore::SequencedEvent.new(
      sequence_position: 1, type: "Foo", data: {}, tags: [],
      created_at: Time.now, id: "evt-1", causation_id: nil,
      correlation_id: "evt-corr", schema_version: 1
    )

    child = ctx.caused_by(event)
    assert_equal "evt-corr", child.correlation_id
  end

  def test_caused_by_falls_back_to_ctx_correlation_when_event_has_none
    store = FakeStore.new
    ctx = DcbEventStore::Client.new(store, correlation_id: "ctx-corr")

    event = DcbEventStore::SequencedEvent.new(
      sequence_position: 1, type: "Foo", data: {}, tags: [],
      created_at: Time.now, id: "evt-1", causation_id: nil,
      correlation_id: nil, schema_version: 1
    )

    child = ctx.caused_by(event)
    assert_equal "ctx-corr", child.correlation_id
  end

  def test_auto_generates_correlation_id_when_not_supplied
    store = FakeStore.new
    ctx = DcbEventStore::Client.new(store)

    refute_nil ctx.correlation_id
    assert_match(/\A[0-9a-f-]{36}\z/, ctx.correlation_id)
  end

  def test_delegates_read
    store = FakeStore.new
    ctx = DcbEventStore::Client.new(store)
    assert_equal %i[read q], ctx.read(:q)
  end

  def test_delegates_read_from
    store = FakeStore.new
    ctx = DcbEventStore::Client.new(store)
    assert_equal [:read_from, :q, 5], ctx.read_from(:q, after: 5)
  end

  def test_passes_condition_through
    store = FakeStore.new
    ctx = DcbEventStore::Client.new(store)
    ctx.append(DcbEventStore::Event.new(type: "X"), :some_condition)
    assert_equal :some_condition, store.appended.first[:condition]
  end

  def test_stamp_preserves_data_and_id
    store = FakeStore.new
    ctx = DcbEventStore::Client.new(store, correlation_id: "c")

    ctx.append(DcbEventStore::Event.new(type: "Foo", data: { "k" => "v" }, id: "my-id"))

    stamped = store.appended.first[:events].first
    assert_equal({ "k" => "v" }, stamped.data)
    assert_equal "my-id", stamped.id
  end

  def test_append_accepts_array_of_events
    store = FakeStore.new
    ctx = DcbEventStore::Client.new(store)

    events = [
      DcbEventStore::Event.new(type: "A"),
      DcbEventStore::Event.new(type: "B")
    ]
    ctx.append(events)

    assert_equal 2, store.appended.first[:events].size
    assert_equal %w[A B], store.appended.first[:events].map(&:type)
  end
end
