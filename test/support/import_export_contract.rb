require "securerandom"
require "stringio"

# Shared contract for Store#import and the EventFile round trip, run against
# every backend (PostgresStore via test/integration/test_store_equivalence.rb,
# SqliteStore via test/sqlite/test_sqlite_store.rb, InMemoryStore via
# test/unit/test_in_memory_store.rb). Including classes set @store to an
# empty store and define #build_store(upcaster: nil) on the same database.
#
# Round trips go through an InMemoryStore on the other side: build_store on
# the SQL backends shares one database, so the backend under test is only
# ever the source or the target of a copy, never both.
module ImportExportContract
  CREATED_AT = Time.utc(2020, 5, 17, 8, 30, 15, 123_456)

  def exported_event(type: "A", **attrs)
    DcbEventStore::SequencedEvent.new(
      sequence_position: 900, type: type, data: { n: 1, nested: { k: "v" } }, tags: ["t:1"],
      created_at: CREATED_AT, id: SecureRandom.uuid, causation_id: SecureRandom.uuid,
      correlation_id: SecureRandom.uuid, schema_version: 3, **attrs
    )
  end

  # Positions are the target's own. created_at to the microsecond: the
  # file's (and the SQL columns') resolution, where InMemoryStore stamps
  # appends with Time.now's nanoseconds.
  def import_comparable(event)
    event.to_h.except(:sequence_position).merge(created_at: event.created_at.floor(6))
  end

  # --- Store#import ---

  def test_import_keeps_id_created_at_schema_version_and_payload
    source = exported_event
    imported = @store.import([source])

    assert_equal 1, imported.size
    assert_equal import_comparable(source), import_comparable(imported[0])
    assert_equal([import_comparable(source)], @store.read(DcbEventStore::Query.all).map { |e| import_comparable(e) })
  end

  def test_import_assigns_positions_in_order_after_existing_events
    appended = @store.append([DcbEventStore::Event.new(type: "Existing")])
    imported = @store.import([exported_event(type: "B"), exported_event(type: "C")])

    head = appended[0].sequence_position
    assert_equal [head + 1, head + 2], imported.map(&:sequence_position)
    assert_equal %w[Existing B C], @store.read(DcbEventStore::Query.all).map(&:type)
    assert_equal imported.last.sequence_position, @store.last_position
  end

  def test_import_wraps_a_single_event
    assert_equal 1, @store.import(exported_event).size
  end

  def test_import_skips_ids_already_stored
    event = exported_event
    @store.import([event])

    assert_empty @store.import([event])
    assert_equal 1, @store.read(DcbEventStore::Query.all).count
  end

  def test_import_of_nothing_returns_empty
    assert_empty @store.import([])
  end

  def test_import_fills_missing_created_at_and_schema_version
    before = Time.now - 5
    imported = @store.import([exported_event(created_at: nil, schema_version: nil)])[0]
    read_back = @store.read(DcbEventStore::Query.all).first

    assert_equal 1, read_back.schema_version
    assert_equal 1, imported.schema_version
    assert_operator read_back.created_at, :>=, before
    assert_operator read_back.created_at, :<=, Time.now + 5
  end

  def test_imported_events_match_tag_queries_and_append_conditions
    @store.import([exported_event(tags: ["course:c1", "student:s1"])])
    query = DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: [], tags: ["course:c1"])])

    assert_equal 1, @store.read(query).count
    condition = DcbEventStore::AppendCondition.new(fail_if_events_match: query)
    assert_raises(DcbEventStore::ConditionNotMet) do
      @store.append([DcbEventStore::Event.new(type: "X", tags: ["course:c1"])], condition)
    end
  end

  # The stored schema_version is what the upcaster starts from, so an event
  # imported at version 2 skips the version-1 step.
  def test_upcaster_starts_from_the_imported_schema_version
    upcaster = DcbEventStore::Upcaster.new
    upcaster.register("A", from_version: 1) { |data| data.merge(v1: true) }
    upcaster.register("A", from_version: 2) { |data| data.merge(v2: true) }
    store = build_store(upcaster: upcaster)
    store.import([exported_event(data: {}, schema_version: 2)])

    read_back = store.read(DcbEventStore::Query.all).first
    assert_equal({ v2: true }, read_back.data)
    assert_equal 3, read_back.schema_version
  end

  # --- EventFile round trips ---

  def test_export_then_import_into_another_store_preserves_every_event
    @store.append([DcbEventStore::Event.new(type: "A", data: { x: 1 }, tags: ["t:1"]),
                   DcbEventStore::Event.new(type: "B", data: { list: [1, { y: "z" }] })])
    io = StringIO.new
    assert_equal 2, DcbEventStore::EventFile.export(@store, io)

    target = DcbEventStore::InMemoryStore.new
    result = DcbEventStore::EventFile.import(target, StringIO.new(io.string))

    assert_equal 2, result.imported
    assert_equal(@store.read(DcbEventStore::Query.all).map { |e| import_comparable(e) },
                 target.read(DcbEventStore::Query.all).map { |e| import_comparable(e) })
  end

  def test_import_of_a_file_exported_elsewhere_preserves_every_event
    source = DcbEventStore::InMemoryStore.new
    source.import([exported_event(type: "A"), exported_event(type: "B", tags: [], data: {})])
    io = StringIO.new
    DcbEventStore::EventFile.export(source, io)

    result = DcbEventStore::EventFile.import(@store, StringIO.new(io.string), batch_size: 1)

    assert_equal [2, 2, 0], [result.read, result.imported, result.skipped]
    assert_equal(source.read(DcbEventStore::Query.all).map { |e| import_comparable(e) },
                 @store.read(DcbEventStore::Query.all).map { |e| import_comparable(e) })
  end

  def test_reimporting_a_file_is_a_no_op
    @store.import([exported_event])
    io = StringIO.new
    DcbEventStore::EventFile.export(@store, io)

    result = DcbEventStore::EventFile.import(@store, StringIO.new(io.string))
    assert_equal [1, 0, 1], [result.read, result.imported, result.skipped]
  end

  def test_export_filters_by_query_and_position
    first = @store.append([DcbEventStore::Event.new(type: "A"), DcbEventStore::Event.new(type: "B")])[0]
    @store.append([DcbEventStore::Event.new(type: "A")])
    io = StringIO.new

    count = DcbEventStore::EventFile.export(
      @store, io,
      query: DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: ["A"])]),
      after: first.sequence_position
    )

    assert_equal 1, count
    assert_equal(["A"], io.string.lines.map { |line| JSON.parse(line)["type"] })
  end
end
