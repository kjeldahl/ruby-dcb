require_relative "../test_helper"

# Unit tests for the MaterializedStreams store decorator, against
# InMemoryStore so no database is involved.
#
# Two things are pinned: the decorator is transparent (every read returns
# exactly what the wrapped store returns, appends and subscriptions pass
# through, and a DecisionModel built through it agrees with one built on the
# store), and it actually caches (a repeated read only asks the store for
# what is new, and streams are evicted least-recently-used).
class TestMaterializedStreams < Minitest::Test
  cover "DcbEventStore::MaterializedStreams*"

  # Counts and records what the decorator asks the wrapped store for.
  class RecordingStore
    attr_reader :calls

    def initialize(store)
      @store = store
      @calls = []
    end

    def read(query)
      @calls << [:read, query.to_s, nil]
      @store.read(query)
    end

    def read_from(query, after:)
      @calls << [:read_from, query.to_s, after]
      @store.read_from(query, after: after)
    end

    def append(events, condition = nil)
      @calls << [:append, Array(events).size, !condition.nil?]
      @store.append(events, condition)
    end

    def subscribe(query, after: nil, &block)
      @calls << [:subscribe, query.to_s, after]
      @store.subscribe(query, after: after, &block)
    end
  end

  def setup
    @store = DcbEventStore::InMemoryStore.new
    @spy = RecordingStore.new(@store)
    @streams = DcbEventStore::MaterializedStreams.new(@spy)
  end

  def item(types, tags = [])
    DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: types, tags: tags)])
  end

  def append(type, tags, data: {})
    @store.append([DcbEventStore::Event.new(type: type, data: data, tags: tags)])
  end

  def positions(events) = events.to_a.map(&:sequence_position)

  # --- transparency ---

  def test_read_returns_the_same_events_as_the_store
    append("A", ["t:1"])
    append("B", ["t:1"])
    append("A", ["t:2"])

    [
      DcbEventStore::Query.all,
      item(["A"]),
      item([], ["t:1"]),
      item(["A"], ["t:1"]),
      DcbEventStore::Query.new([
                                 DcbEventStore::QueryItem.new(event_types: ["A"], tags: ["t:2"]),
                                 DcbEventStore::QueryItem.new(event_types: ["B"], tags: ["t:1"])
                               ])
    ].each do |query|
      assert_equal @store.read(query).to_a, @streams.read(query).to_a, "diverged for #{query}"
    end
  end

  def test_read_returns_an_empty_stream_for_a_query_matching_nothing
    append("A", ["t:1"])

    assert_empty @streams.read(item(["Nope"])).to_a
  end

  # A multi-item query is served by merging its items' streams: ascending
  # order, and an event selected by both items appears once.
  def test_multi_item_query_merges_its_items_streams_without_duplicates
    append("A", ["t:1", "t:2"])
    append("A", ["t:1"])
    append("A", ["t:2"])
    query = DcbEventStore::Query.new([
                                       DcbEventStore::QueryItem.new(event_types: ["A"], tags: ["t:1"]),
                                       DcbEventStore::QueryItem.new(event_types: ["A"], tags: ["t:2"])
                                     ])

    assert_equal [1, 2, 3], positions(@streams.read(query))
    assert_equal positions(@store.read(query)), positions(@streams.read(query))
  end

  def test_read_from_returns_the_same_events_as_the_store
    3.times { append("A", ["t:1"]) }

    (0..3).each do |after|
      assert_equal @store.read_from(item(["A"]), after: after).to_a,
                   @streams.read_from(item(["A"]), after: after).to_a,
                   "diverged for after: #{after}"
    end
  end

  def test_store_is_exposed
    assert_same @spy, @streams.store
  end

  # The decorator hands out an enumerator, not the array it caches: a caller
  # that pushed onto the returned collection would otherwise corrupt a stream.
  def test_read_returns_an_enumerator_over_a_copy
    append("A", ["t:1"])

    events = @streams.read(item(["A"]))
    assert_instance_of Enumerator, events
    events.to_a << "not an event"

    assert_equal 1, @streams.read(item(["A"])).to_a.size
  end

  def test_read_from_returns_an_enumerator
    append("A", ["t:1"])

    assert_instance_of Enumerator, @streams.read_from(item(["A"]), after: 0)
  end

  # --- caching ---

  def test_first_read_issues_one_store_read_per_query_item
    append("A", ["t:1"])
    query = DcbEventStore::Query.new([
                                       DcbEventStore::QueryItem.new(event_types: ["A"], tags: ["t:1"]),
                                       DcbEventStore::QueryItem.new(event_types: ["B"], tags: ["t:2"])
                                     ])

    @streams.read(query).to_a

    assert_equal [[:read, "Query[A{t:1}]", nil], [:read, "Query[B{t:2}]", nil]], @spy.calls
    assert_equal 2, @streams.size
  end

  def test_second_read_only_asks_the_store_for_what_is_new
    append("A", ["t:1"])
    @streams.read(item(["A"])).to_a
    @spy.calls.clear

    assert_equal [1], positions(@streams.read(item(["A"])))
    assert_equal [[:read_from, "Query[A]", 1]], @spy.calls
  end

  def test_a_repeated_read_picks_up_events_appended_since
    append("A", ["t:1"])
    assert_equal [1], positions(@streams.read(item(["A"])))

    append("A", ["t:1"])
    @spy.calls.clear

    assert_equal [1, 2], positions(@streams.read(item(["A"])))
    assert_equal [[:read_from, "Query[A]", 1]], @spy.calls
    assert_equal 2, @streams.event_count
  end

  # An empty stream is kept, but it has no position to extend from, so the
  # next read asks for it in full again.
  def test_an_empty_stream_is_re_read_in_full
    @streams.read(item(["A"])).to_a
    @spy.calls.clear

    append("A", ["t:1"])
    assert_equal [1], positions(@streams.read(item(["A"])))
    assert_equal [[:read_from, "Query[A]", nil]], @spy.calls
  end

  def test_read_from_for_a_known_query_is_served_from_the_materialized_stream
    3.times { append("A", ["t:1"]) }
    @streams.read(item(["A"])).to_a
    @spy.calls.clear

    assert_equal [2, 3], positions(@streams.read_from(item(["A"]), after: 1))
    assert_equal [[:read_from, "Query[A]", 3]], @spy.calls, "only the tail should be fetched"
  end

  # A read_from for a query the decorator has never seen materializes it too,
  # then filters: the stream is complete, so it can be extended later.
  def test_read_from_for_an_unknown_query_materializes_the_stream
    3.times { append("A", ["t:1"]) }

    assert_equal [3], positions(@streams.read_from(item(["A"]), after: 2))
    assert_equal [[:read, "Query[A]", nil]], @spy.calls
    assert_equal 1, @streams.size
    assert_equal 3, @streams.event_count
  end

  def test_query_all_is_a_stream_of_its_own
    append("A", ["t:1"])
    @streams.read(item(["A"])).to_a
    @streams.read(DcbEventStore::Query.all).to_a

    assert_equal 2, @streams.size
    assert_equal 2, @streams.event_count
  end

  def test_size_and_event_count_start_at_zero
    assert_equal 0, @streams.size
    assert_equal 0, @streams.event_count
  end

  def test_clear_drops_every_stream
    2.times { append("A", ["t:1"]) }
    @streams.read(item(["A"])).to_a

    assert_nil @streams.clear
    assert_equal 0, @streams.size
    assert_equal 0, @streams.event_count

    @spy.calls.clear
    assert_equal [1, 2], positions(@streams.read(item(["A"])))
    assert_equal [[:read, "Query[A]", nil]], @spy.calls
  end

  # --- eviction ---

  # The documented default: a thousand item streams, evicted least recently
  # used past that.
  def test_max_streams_defaults_to_one_thousand
    streams = DcbEventStore::MaterializedStreams.new(@spy)
    1_001.times { |i| streams.read(item(["T#{i}"])).to_a }

    assert_equal 1_000, streams.size
  end

  def test_streams_are_evicted_once_max_streams_is_exceeded
    streams = DcbEventStore::MaterializedStreams.new(@spy, max_streams: 2)
    append("A", ["t:1"])
    append("B", ["t:1"])
    append("C", ["t:1"])

    streams.read(item(["A"])).to_a
    streams.read(item(["B"])).to_a
    streams.read(item(["C"])).to_a

    assert_equal 2, streams.size
    assert_equal 2, streams.event_count

    # A was the least recently used, so it is gone and must be read in full.
    @spy.calls.clear
    assert_equal [1], positions(streams.read(item(["A"])))
    assert_equal [[:read, "Query[A]", nil]], @spy.calls
  end

  def test_eviction_keeps_the_most_recently_used_stream
    streams = DcbEventStore::MaterializedStreams.new(@spy, max_streams: 2)
    append("A", ["t:1"])
    append("B", ["t:1"])
    append("C", ["t:1"])

    streams.read(item(["A"])).to_a
    streams.read(item(["B"])).to_a
    streams.read(item(["A"])).to_a # A becomes the most recent again
    streams.read(item(["C"])).to_a # evicts B, not A

    @spy.calls.clear
    streams.read(item(["A"])).to_a
    assert_equal [[:read_from, "Query[A]", 1]], @spy.calls
  end

  def test_streams_are_evicted_once_max_events_is_exceeded
    streams = DcbEventStore::MaterializedStreams.new(@spy, max_events: 2)
    2.times { append("A", ["t:1"]) }
    2.times { append("B", ["t:1"]) }

    streams.read(item(["A"])).to_a
    assert_equal 2, streams.event_count

    streams.read(item(["B"])).to_a

    assert_equal 1, streams.size
    assert_equal 2, streams.event_count

    @spy.calls.clear
    streams.read(item(["A"])).to_a
    assert_equal [[:read, "Query[A]", nil]], @spy.calls
  end

  # The last stream standing is kept whatever its size: evicting it would
  # leave the cache unable to serve anything at all.
  def test_a_single_oversized_stream_is_kept
    streams = DcbEventStore::MaterializedStreams.new(@spy, max_events: 1)
    3.times { append("A", ["t:1"]) }

    streams.read(item(["A"])).to_a

    assert_equal 1, streams.size
    assert_equal 3, streams.event_count
  end

  # --- pass-through ---

  def test_append_passes_through_and_is_visible_to_the_next_read
    appended = @streams.append([DcbEventStore::Event.new(type: "A", tags: ["t:1"])])

    assert_equal [1], appended.map(&:sequence_position)
    assert_equal [[:append, 1, false]], @spy.calls
    assert_equal [1], positions(@streams.read(item(["A"])))
  end

  def test_append_passes_the_condition_through
    append("A", ["t:1"])
    condition = DcbEventStore::AppendCondition.new(fail_if_events_match: item(["A"]))

    assert_raises(DcbEventStore::ConditionNotMet) do
      @streams.append([DcbEventStore::Event.new(type: "A", tags: ["t:1"])], condition)
    end
    assert_equal [:append, 1, true], @spy.calls.last
  end

  def test_append_through_the_wrapper_is_picked_up_by_a_materialized_stream
    append("A", ["t:1"])
    assert_equal [1], positions(@streams.read(item(["A"])))

    @streams.append([DcbEventStore::Event.new(type: "A", tags: ["t:1"])])

    assert_equal [1, 2], positions(@streams.read(item(["A"])))
  end

  def test_subscribe_passes_through
    append("A", ["t:1"])
    received = []

    assert_nil @streams.subscribe(item(["A"])) { |event| received << event }

    assert_equal [1], received.map(&:sequence_position)
    assert_equal [:subscribe, "Query[A]", nil], @spy.calls.last
  end

  def test_subscribe_passes_after_through
    2.times { append("A", ["t:1"]) }
    received = []

    @streams.subscribe(item(["A"]), after: 1) { |event| received << event }

    assert_equal [2], received.map(&:sequence_position)
    assert_equal [:subscribe, "Query[A]", 1], @spy.calls.last
  end

  # --- through DecisionModel ---

  # The decorator has to be invisible to the thing it exists for: the same
  # decision model built on the store and through the wrapper, over a
  # sequence of appends.
  def test_decision_model_agrees_with_the_plain_store_across_appends
    projections = {
      a: counter("Increment", "counter:a"),
      b: counter("Increment", "counter:b"),
      wide: DcbEventStore::Projection.new(
        initial_state: 0,
        handlers: { "Increment" => ->(s, _e) { s + 1 }, "Other" => ->(s, _e) { s + 1 } },
        query: DcbEventStore::Query.new([
                                          DcbEventStore::QueryItem.new(event_types: [], tags: ["counter:a"]),
                                          DcbEventStore::QueryItem.new(event_types: ["Other"], tags: ["counter:b"])
                                        ])
      )
    }

    assert_decision_models_agree(projections)

    append("Increment", ["counter:a"])
    assert_decision_models_agree(projections)

    append("Other", ["counter:a"])
    append("Increment", ["counter:b"])
    assert_decision_models_agree(projections)

    @streams.append([DcbEventStore::Event.new(type: "Increment", tags: ["counter:a", "counter:b"])])
    assert_decision_models_agree(projections)
    assert_decision_models_agree(projections)
  end

  # The condition a build through the wrapper returns must still reject a
  # racing append.
  def test_decision_model_condition_through_the_wrapper_still_guards
    append("Increment", ["counter:a"])
    result = DcbEventStore::DecisionModel.build(@streams, a: counter("Increment", "counter:a"))

    append("Increment", ["counter:a"])

    assert_raises(DcbEventStore::ConditionNotMet) do
      @streams.append([DcbEventStore::Event.new(type: "Increment", tags: ["counter:a"])],
                      result.append_condition)
    end
  end

  private

  def counter(type, tag)
    DcbEventStore::Projection.new(
      initial_state: 0,
      handlers: { type => ->(s, _e) { s + 1 } },
      query: DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: [type], tags: [tag])])
    )
  end

  def assert_decision_models_agree(projections)
    plain = DcbEventStore::DecisionModel.build(@store, **projections)
    wrapped = DcbEventStore::DecisionModel.build(@streams, **projections)

    assert_equal plain.states, wrapped.states
    assert_equal [plain.append_condition.after], [wrapped.append_condition.after]
  end
end
