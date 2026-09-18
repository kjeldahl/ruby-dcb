require "securerandom"

# Shared behavioral contract for DcbEventStore stores: append, read,
# read_from, pagination and instrumentation.
#
# Every store implementation (PostgresStore, InMemoryStore) must
# pass these tests with identical observable behavior. Including classes
# must set @store in setup and define #build_store(upcaster: nil) returning
# a fresh, empty store.
#
# Siblings covering the rest of the backend-neutral behavior:
# SpecialCharactersContract, ClientContract, DecisionModelContract,
# UpcasterContract.
module StoreContract
  # --- append ---

  def test_append_without_condition
    event = DcbEventStore::Event.new(type: "A", data: {x: 1}, tags: ["t:1"])
    result = @store.append([event])

    assert_equal 1, result.size
    assert_kind_of DcbEventStore::SequencedEvent, result[0]
    assert_equal "A", result[0].type
    assert_equal({x: 1}, result[0].data)
    assert_equal ["t:1"], result[0].tags
    assert_kind_of Integer, result[0].sequence_position
    assert_kind_of Time, result[0].created_at
    assert_equal event.id, result[0].id
    assert_equal 1, result[0].schema_version
  end

  def test_append_single_event_without_array
    result = @store.append(DcbEventStore::Event.new(type: "A"))
    assert_equal 1, result.size
    assert_equal "A", result[0].type
  end

  def test_append_empty_array_returns_empty
    assert_empty @store.append([])
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

  def test_append_preserves_metadata
    event = DcbEventStore::Event.new(
      type: "A",
      causation_id: (cause = SecureRandom.uuid),
      correlation_id: (corr = SecureRandom.uuid)
    )
    result = @store.append([event])

    assert_equal cause, result[0].causation_id
    assert_equal corr, result[0].correlation_id
  end

  def test_append_condition_passes
    query = DcbEventStore::Query.new([
                                       DcbEventStore::QueryItem.new(event_types: ["Conflict"])
                                     ])
    condition = DcbEventStore::AppendCondition.new(fail_if_events_match: query)

    result = @store.append([DcbEventStore::Event.new(type: "Safe")], condition)
    assert_equal 1, result.size
  end

  def test_append_condition_fails
    @store.append([DcbEventStore::Event.new(type: "Conflict")])

    query = DcbEventStore::Query.new([
                                       DcbEventStore::QueryItem.new(event_types: ["Conflict"])
                                     ])
    condition = DcbEventStore::AppendCondition.new(fail_if_events_match: query)

    error = assert_raises(DcbEventStore::ConditionNotMet) do
      @store.append([DcbEventStore::Event.new(type: "Another")], condition)
    end
    assert_equal "conflicting event(s)", error.message
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

  def test_condition_not_met_is_rescuable
    assert DcbEventStore::ConditionNotMet < StandardError
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

  def test_condition_match_all_no_after
    @store.append([DcbEventStore::Event.new(type: "A")])

    condition = DcbEventStore::AppendCondition.new(
      fail_if_events_match: DcbEventStore::Query.all
    )

    assert_raises(DcbEventStore::ConditionNotMet) do
      @store.append([DcbEventStore::Event.new(type: "B")], condition)
    end
  end

  def test_condition_match_all_with_after
    first = @store.append([DcbEventStore::Event.new(type: "A")])

    condition = DcbEventStore::AppendCondition.new(
      fail_if_events_match: DcbEventStore::Query.all,
      after: first[0].sequence_position
    )

    result = @store.append([DcbEventStore::Event.new(type: "B")], condition)
    assert_equal 1, result.size
  end

  def test_condition_with_tag_filter_no_event_types
    @store.append([DcbEventStore::Event.new(type: "A", tags: ["tenant:t1"])])

    query = DcbEventStore::Query.new([
                                       DcbEventStore::QueryItem.new(event_types: [], tags: ["tenant:t1"])
                                     ])
    condition = DcbEventStore::AppendCondition.new(fail_if_events_match: query)

    assert_raises(DcbEventStore::ConditionNotMet) do
      @store.append([DcbEventStore::Event.new(type: "B")], condition)
    end
  end

  def test_duplicate_event_id_silently_skipped
    id = SecureRandom.uuid
    e1 = DcbEventStore::Event.new(type: "A", id: id)
    e2 = DcbEventStore::Event.new(type: "A", id: id)

    r1 = @store.append([e1])
    assert_equal 1, r1.size

    r2 = @store.append([e2])
    assert_equal 0, r2.size

    all = @store.read(DcbEventStore::Query.all).to_a
    assert_equal 1, all.size
  end

  def test_duplicate_event_id_with_different_payload_skipped
    id = SecureRandom.uuid
    @store.append([DcbEventStore::Event.new(type: "A", data: {v: 1}, id: id)])
    result = @store.append([DcbEventStore::Event.new(type: "B", data: {v: 2}, id: id)])

    assert_equal 0, result.size

    all = @store.read(DcbEventStore::Query.all).to_a
    assert_equal 1, all.size
    assert_equal "A", all[0].type
    assert_equal({v: 1}, all[0].data)
  end

  def test_mixed_batch_some_duplicates
    id1 = SecureRandom.uuid
    @store.append([DcbEventStore::Event.new(type: "A", id: id1)])

    id2 = SecureRandom.uuid
    batch = [
      DcbEventStore::Event.new(type: "A", id: id1),
      DcbEventStore::Event.new(type: "B", id: id2)
    ]
    result = @store.append(batch)

    assert_equal 1, result.size
    assert_equal "B", result[0].type
    assert_equal id2, result[0].id

    all = @store.read(DcbEventStore::Query.all).to_a
    assert_equal 2, all.size
  end

  def test_idempotent_with_condition
    e = DcbEventStore::Event.new(type: "A", id: SecureRandom.uuid, tags: ["t:1"])

    query = DcbEventStore::Query.new([
                                       DcbEventStore::QueryItem.new(event_types: ["Other"])
                                     ])
    condition = DcbEventStore::AppendCondition.new(fail_if_events_match: query)

    @store.append([e], condition)
    r2 = @store.append([e], condition)
    assert_equal 0, r2.size
  end

  # --- read ---

  def test_read_returns_enumerator
    assert_kind_of Enumerator, @store.read(DcbEventStore::Query.all)
    assert_kind_of Enumerator, @store.read_from(DcbEventStore::Query.all, after: 0)
  end

  def test_read_empty_store
    events = @store.read(DcbEventStore::Query.all).to_a
    assert_empty events
  end

  def test_read_all_returns_all_events
    @store.append([DcbEventStore::Event.new(type: "A", tags: ["x:1"])])
    @store.append([DcbEventStore::Event.new(type: "B", tags: ["y:2"])])

    events = @store.read(DcbEventStore::Query.all).to_a
    assert_equal 2, events.size
    assert_equal %w[A B], events.map(&:type)
  end

  def test_read_filters_by_type
    @store.append([DcbEventStore::Event.new(type: "A")])
    @store.append([DcbEventStore::Event.new(type: "B")])

    query = DcbEventStore::Query.new([
                                       DcbEventStore::QueryItem.new(event_types: ["A"])
                                     ])
    events = @store.read(query).to_a
    assert_equal 1, events.size
    assert_equal "A", events[0].type
  end

  def test_read_filters_by_tag
    @store.append([DcbEventStore::Event.new(type: "A", tags: ["course:c1"])])
    @store.append([DcbEventStore::Event.new(type: "A", tags: ["course:c2"])])

    query = DcbEventStore::Query.new([
                                       DcbEventStore::QueryItem.new(event_types: ["A"], tags: ["course:c1"])
                                     ])
    events = @store.read(query).to_a
    assert_equal 1, events.size
    assert_equal ["course:c1"], events[0].tags
  end

  def test_read_tags_must_contain_all
    @store.append([DcbEventStore::Event.new(type: "A", tags: ["student:s1", "course:c1"])])
    @store.append([DcbEventStore::Event.new(type: "A", tags: ["student:s1"])])

    query = DcbEventStore::Query.new([
                                       DcbEventStore::QueryItem.new(event_types: ["A"],
                                                                    tags: [
                                                                      "student:s1", "course:c1"
                                                                    ])
                                     ])
    events = @store.read(query).to_a
    assert_equal 1, events.size
    assert_equal ["student:s1", "course:c1"], events[0].tags
  end

  # A tag repeated on one event, and a duplicate tag in the query itself, must
  # not change what matches: backends that count tag matches in an index table
  # have to deduplicate both sides.
  def test_read_matches_event_with_duplicate_tags
    @store.append([DcbEventStore::Event.new(type: "A", tags: %w[dup dup])])

    query = DcbEventStore::Query.new([
                                       DcbEventStore::QueryItem.new(event_types: ["A"], tags: ["dup"])
                                     ])
    events = @store.read(query).to_a
    assert_equal 1, events.size
    assert_equal %w[dup dup], events[0].tags
  end

  def test_read_with_duplicate_tags_in_query
    @store.append([DcbEventStore::Event.new(type: "A", tags: ["t:1"])])

    query = DcbEventStore::Query.new([
                                       DcbEventStore::QueryItem.new(event_types: [], tags: ["t:1", "t:1"])
                                     ])
    assert_equal 1, @store.read(query).to_a.size
  end

  def test_read_or_across_query_items
    @store.append([DcbEventStore::Event.new(type: "A", tags: ["x:1"])])
    @store.append([DcbEventStore::Event.new(type: "B", tags: ["y:2"])])
    @store.append([DcbEventStore::Event.new(type: "C", tags: ["z:3"])])

    query = DcbEventStore::Query.new([
                                       DcbEventStore::QueryItem.new(event_types: ["A"]),
                                       DcbEventStore::QueryItem.new(event_types: ["B"])
                                     ])
    events = @store.read(query).to_a
    assert_equal 2, events.size
    assert_equal %w[A B], events.map(&:type)
  end

  def test_read_ordered_by_sequence_position
    @store.append([DcbEventStore::Event.new(type: "A")])
    @store.append([DcbEventStore::Event.new(type: "B")])
    @store.append([DcbEventStore::Event.new(type: "C")])

    events = @store.read(DcbEventStore::Query.all).to_a
    positions = events.map(&:sequence_position)
    assert_equal positions.sort, positions
  end

  def test_sequenced_event_types
    @store.append([DcbEventStore::Event.new(type: "A", data: {x: 1}, tags: ["t:1"])])

    event = @store.read(DcbEventStore::Query.all).first
    assert_kind_of Integer, event.sequence_position
    assert_kind_of String, event.type
    assert_kind_of Hash, event.data
    assert_kind_of Array, event.tags
    assert_kind_of Time, event.created_at
    assert_equal({x: 1}, event.data)
  end

  def test_read_symbolizes_string_data_keys
    @store.append([DcbEventStore::Event.new(type: "A", data: {"x" => 1, "nested" => {"y" => 2}})])

    event = @store.read(DcbEventStore::Query.all).first
    assert_equal({x: 1, nested: {y: 2}}, event.data)
  end

  def test_read_filters_by_tag_only_no_event_types
    @store.append([DcbEventStore::Event.new(type: "A", tags: ["tenant:t1"])])
    @store.append([DcbEventStore::Event.new(type: "B", tags: ["tenant:t1"])])
    @store.append([DcbEventStore::Event.new(type: "C", tags: ["tenant:t2"])])

    query = DcbEventStore::Query.new([
                                       DcbEventStore::QueryItem.new(event_types: [], tags: ["tenant:t1"])
                                     ])
    events = @store.read(query).to_a
    assert_equal 2, events.size
    assert(events.all? { |e| e.tags.include?("tenant:t1") })
  end

  def test_read_metadata_round_trip
    event = DcbEventStore::Event.new(
      type: "A",
      causation_id: (cause = SecureRandom.uuid),
      correlation_id: (corr = SecureRandom.uuid)
    )
    @store.append([event])

    read_back = @store.read(DcbEventStore::Query.all).first
    assert_equal event.id, read_back.id
    assert_equal cause, read_back.causation_id
    assert_equal corr, read_back.correlation_id
    assert_equal 1, read_back.schema_version
  end

  # --- read_from ---

  def test_read_from_returns_events_after_position
    appended = @store.append([
                               DcbEventStore::Event.new(type: "A"),
                               DcbEventStore::Event.new(type: "B"),
                               DcbEventStore::Event.new(type: "C")
                             ])

    events = @store.read_from(DcbEventStore::Query.all, after: appended[0].sequence_position).to_a
    assert_equal %w[B C], events.map(&:type)
  end

  def test_read_from_with_type_and_tag_filter_after_position
    appended = @store.append([
                               DcbEventStore::Event.new(type: "A", tags: ["course:c1"]),
                               DcbEventStore::Event.new(type: "A", tags: ["course:c2"]),
                               DcbEventStore::Event.new(type: "B", tags: ["course:c1"]),
                               DcbEventStore::Event.new(type: "A", tags: ["course:c1"])
                             ])

    query = DcbEventStore::Query.new([
                                       DcbEventStore::QueryItem.new(event_types: ["A"], tags: ["course:c1"])
                                     ])
    events = @store.read_from(query, after: appended[1].sequence_position).to_a
    assert_equal 1, events.size
    assert_equal "A", events[0].type
    assert_equal ["course:c1"], events[0].tags
    assert events[0].sequence_position > appended[1].sequence_position
  end

  def test_read_from_with_filtered_query
    appended = 5.times.flat_map { @store.append([DcbEventStore::Event.new(type: "A")]) }
    5.times { @store.append([DcbEventStore::Event.new(type: "B")]) }

    query = DcbEventStore::Query.new([
                                       DcbEventStore::QueryItem.new(event_types: ["A"])
                                     ])
    after = appended[2].sequence_position
    events = @store.read_from(query, after: after).to_a
    assert_equal 2, events.size
    assert(events.all? { |e| e.type == "A" && e.sequence_position > after })
  end

  def test_read_from_zero_returns_all
    3.times { @store.append([DcbEventStore::Event.new(type: "X")]) }

    events = @store.read_from(DcbEventStore::Query.all, after: 0).to_a
    assert_equal 3, events.size
  end

  def test_read_from_multi_item_query_with_after
    appended = %w[A B C A B].flat_map { |type| @store.append([DcbEventStore::Event.new(type: type)]) }

    query = DcbEventStore::Query.new([
                                       DcbEventStore::QueryItem.new(event_types: ["A"]),
                                       DcbEventStore::QueryItem.new(event_types: ["C"])
                                     ])
    after = appended[1].sequence_position
    events = @store.read_from(query, after: after).to_a
    assert_equal %w[C A], events.map(&:type)
    assert(events.all? { |e| e.sequence_position > after })
  end

  def test_read_from_beyond_last_returns_empty
    appended = @store.append([DcbEventStore::Event.new(type: "X")])

    events = @store.read_from(DcbEventStore::Query.all,
                              after: appended[0].sequence_position + 100).to_a
    assert_empty events
  end

  # --- instrumentation ---

  def test_append_emits_instrumentation_event
    seen = with_instrumentation do
      @store.append([DcbEventStore::Event.new(type: "A")])
    end

    appends = seen.select { |event| event.name == "append.dcb" }
    assert_equal 1, appends.size
    assert_equal 1, appends[0].payload[:event_count]
    assert_equal 1, appends[0].payload[:appended_count]
    assert_kind_of Integer, appends[0].payload[:last_position]
  end

  def test_read_emits_instrumentation_event_with_count
    @store.append([DcbEventStore::Event.new(type: "A"), DcbEventStore::Event.new(type: "B")])

    seen = with_instrumentation { @store.read(DcbEventStore::Query.all).to_a }

    reads = seen.select { |event| event.name == "read.dcb" }
    assert_equal 1, reads.size
    assert_equal 2, reads[0].payload[:event_count]
  end

  def test_failed_append_condition_emits_instrumentation_error
    @store.append([DcbEventStore::Event.new(type: "Conflict")])
    query = DcbEventStore::Query.new([
                                       DcbEventStore::QueryItem.new(event_types: ["Conflict"])
                                     ])
    condition = DcbEventStore::AppendCondition.new(fail_if_events_match: query)

    seen = with_instrumentation do
      assert_raises(DcbEventStore::ConditionNotMet) do
        @store.append([DcbEventStore::Event.new(type: "Another")], condition)
      end
    end

    appends = seen.select { |event| event.name == "append.dcb" }
    assert_equal 1, appends.size
    assert_instance_of DcbEventStore::ConditionNotMet, appends[0].error
  end

  # Swaps in a fresh global Notifications instance for the duration of the
  # block and returns the events published while it ran.
  def with_instrumentation
    previous = DcbEventStore.instrumentation
    DcbEventStore.instrumentation = DcbEventStore::Notifications.new
    seen = []
    DcbEventStore.instrumentation.subscribe { |event| seen << event }
    yield
    seen
  ensure
    DcbEventStore.instrumentation = previous
  end

  # --- pagination ---

  # SQL backends read in batches of BATCH_SIZE using keyset pagination on
  # sequence_position, so a result set larger than one batch must come back
  # complete, in order, and without duplicates or gaps at the boundary.
  BATCH_SIZE = DcbEventStore::SqlStore::BATCH_SIZE
  APPEND_CHUNK = 500

  def test_read_returns_all_rows_across_batch_boundary
    total = (BATCH_SIZE * 2) + 50
    append_many(total)

    positions = @store.read(DcbEventStore::Query.all).map(&:sequence_position)

    assert_equal total, positions.size
    assert_equal positions.sort, positions
    assert_equal positions.uniq, positions
  end

  def test_read_from_paginates_across_batch_boundary
    total = BATCH_SIZE + 25
    appended = append_many(total)
    after = appended[9].sequence_position

    positions = @store.read_from(DcbEventStore::Query.all, after: after).map(&:sequence_position)

    assert_equal total - 10, positions.size
    assert(positions.all? { |p| p > after })
    assert_equal positions.sort, positions
    assert_equal positions.uniq, positions
  end

  # Appends `count` events in chunks, so crossing the read batch boundary
  # does not depend on any backend-specific bulk insert.
  def append_many(count, type: "A")
    (1..count).each_slice(APPEND_CHUNK).flat_map do |slice|
      @store.append(slice.map { DcbEventStore::Event.new(type: type) })
    end
  end
end
