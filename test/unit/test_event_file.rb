require_relative "../test_helper"
require "stringio"
require "tmpdir"

# EventFile's line format and IO handling, against InMemoryStore and a
# recording fake. The per-backend round trips live in ImportExportContract.
class TestEventFile < Minitest::Test
  cover "DcbEventStore::EventFile*"

  EventFile = DcbEventStore::EventFile

  # Records the batches EventFile hands to #import.
  class RecordingStore
    attr_reader :batches

    def initialize(skip_ids: [])
      @batches = []
      @skip_ids = skip_ids
    end

    def import(events)
      @batches << events
      events.reject { |e| @skip_ids.include?(e.id) }
    end
  end

  def sequenced(**attrs)
    DcbEventStore::SequencedEvent.new(
      sequence_position: 7, type: "A", data: { n: 1, list: [{ k: "v" }] }, tags: ["t:1"],
      created_at: Time.new(2026, 6, 13, 22, 0, Rational(123_456, 1_000_000), "+02:00"),
      id: "id-1", causation_id: "c-1", correlation_id: "r-1", schema_version: 2, **attrs
    )
  end

  # --- encode ---

  def test_encode_writes_every_field_in_order_with_utc_microseconds
    expected = '{"sequence_position":7,"id":"id-1","type":"A","tags":["t:1"],"data":{"n":1,"list":[{"k":"v"}]},' \
               '"causation_id":"c-1","correlation_id":"r-1","schema_version":2,' \
               '"created_at":"2026-06-13T20:00:00.123456Z"}'
    assert_equal expected, EventFile.encode(sequenced)
  end

  def test_encode_does_not_change_the_events_time
    event = sequenced
    EventFile.encode(event)
    assert_equal "+02:00", event.created_at.strftime("%:z")
  end

  def test_encode_of_a_missing_created_at
    assert_includes EventFile.encode(sequenced(created_at: nil)), '"created_at":null'
  end

  # --- decode ---

  def test_decode_inverts_encode
    event = sequenced
    assert_equal event, EventFile.decode(EventFile.encode(event))
  end

  def test_decode_symbolizes_nested_data_keys
    decoded = EventFile.decode('{"type":"A","data":{"a":{"b":[{"c":1}]}}}')
    assert_equal({ a: { b: [{ c: 1 }] } }, decoded.data)
  end

  def test_decode_fills_defaults_for_a_minimal_line
    decoded = EventFile.decode('{"type":"A"}')

    assert_equal "A", decoded.type
    assert_equal({}, decoded.data)
    assert_equal [], decoded.tags
    assert_equal 1, decoded.schema_version
    assert_nil decoded.created_at
    assert_nil decoded.sequence_position
    assert_nil decoded.causation_id
    assert_nil decoded.correlation_id
    assert_match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/, decoded.id)
    refute_equal decoded.id, EventFile.decode('{"type":"A"}').id
  end

  def test_decode_of_null_data_and_tags
    decoded = EventFile.decode('{"type":"A","data":null,"tags":null}')
    assert_equal [{}, []], [decoded.data, decoded.tags]
  end

  def test_decode_stringifies_type_and_tags
    decoded = EventFile.decode('{"type":1,"tags":[2,"x"]}')
    assert_equal ["1", %w[2 x]], [decoded.type, decoded.tags]
  end

  def test_decode_rejects_bad_lines
    {
      "not json" => /\Ainvalid JSON: \S/,
      "[1]" => /\Aexpected a JSON object, got Array\z/,
      '{"data":{}}' => /\Amissing "type"\z/,
      '{"type":""}' => /\Amissing "type"\z/,
      '{"type":"A","tag":["x"],"extra":1}' => /\Aunknown key\(s\): tag, extra\z/,
      '{"type":"A","created_at":"yesterday"}' => /yesterday/
    }.each do |line, message|
      error = assert_raises(ArgumentError, line) { EventFile.decode(line) }
      assert_match message, error.message, line
    end
  end

  # --- each_event ---

  def test_each_event_skips_blank_lines_and_names_the_bad_line
    io = StringIO.new(%({"type":"A"}\n\n   \n{"type":"B"}\n{"nope":1}\n))
    types = []
    error = assert_raises(ArgumentError) { EventFile.each_event(io) { |e| types << e.type } }

    assert_equal %w[A B], types
    assert_equal "line 5: unknown key(s): nope", error.message
  end

  def test_each_event_without_a_block_is_lazy
    enum = EventFile.each_event(StringIO.new(%({"type":"A"}\nbroken\n)))
    assert_kind_of Enumerator, enum
    assert_equal "A", enum.first.type
  end

  # --- export ---

  def test_export_to_an_io_returns_the_count
    store = DcbEventStore::InMemoryStore.new
    store.append([DcbEventStore::Event.new(type: "A"), DcbEventStore::Event.new(type: "B")])
    io = StringIO.new

    assert_equal 2, EventFile.export(store, io)
    assert_equal([1, 2], io.string.lines.drop(1).map { |l| JSON.parse(l)["sequence_position"] })
    assert io.string.end_with?("\n")
  end

  def test_export_of_an_empty_store
    io = StringIO.new
    assert_equal 0, EventFile.export(DcbEventStore::InMemoryStore.new, io)
    assert_equal 1, io.string.lines.size
    assert_equal EventFile::FORMAT, JSON.parse(io.string)["format"]
  end

  def test_export_filters_by_query_and_position
    store = DcbEventStore::InMemoryStore.new
    store.append(%w[A B A B].map { |type| DcbEventStore::Event.new(type: type) })
    query = DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: ["A"])])

    [[{}, [1, 2, 3, 4]], [{ query: query }, [1, 3]], [{ after: 1 }, [2, 3, 4]],
     [{ query: query, after: 1 }, [3]], [{ after: 0 }, [1, 2, 3, 4]]].each do |options, positions|
      io = StringIO.new
      EventFile.export(store, io, **options)
      assert_equal positions, io.string.lines.drop(1).map { |l| JSON.parse(l)["sequence_position"] }, options.inspect
    end
  end

  def test_export_and_import_through_string_and_pathname_paths
    store = DcbEventStore::InMemoryStore.new
    store.append([DcbEventStore::Event.new(type: "A")])
    ids = store.read(DcbEventStore::Query.all).map(&:id)

    Dir.mktmpdir do |dir|
      [File.join(dir, "a.jsonl"), Pathname.new(File.join(dir, "b.jsonl"))].each do |path|
        assert_equal 1, EventFile.export(store, path)

        [path.to_s, Pathname.new(path.to_s)].each do |source|
          target = DcbEventStore::InMemoryStore.new
          assert_equal 1, EventFile.import(target, source).imported
          assert_equal ids, target.read(DcbEventStore::Query.all).map(&:id)
        end
      end
    end
  end

  # A path is a file name, never a "|command" for Kernel#open to run.
  def test_a_path_starting_with_a_pipe_is_a_file
    store = DcbEventStore::InMemoryStore.new
    store.append([DcbEventStore::Event.new(type: "A")])

    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        EventFile.export(store, "|touch pwned")
        refute File.exist?("pwned")
        assert_equal ["A"], EventFile.each_event("|touch pwned").map(&:type)
      end
    end
  end

  # --- header ---

  def test_encode_header_writes_every_field_in_order
    query = DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: %w[A B], tags: ["t:1"]),
                                      DcbEventStore::QueryItem.new(event_types: [], tags: ["t:2"])])
    line = EventFile::Header.encode(
      store: DcbEventStore::InMemoryStore.new, query: query, after: 7, description: "staging seed",
      exported_at: Time.new(2026, 9, 26, 10, 0, Rational(1, 1_000_000), "+02:00")
    )

    expected = '{"format":"dcb_event_store/events","version":1,"exported_at":"2026-09-26T08:00:00.000001Z",' \
               "\"gem_version\":\"#{DcbEventStore::VERSION}\",\"store\":\"DcbEventStore::InMemoryStore\"," \
               '"query":[{"types":["A","B"],"tags":["t:1"]},{"types":[],"tags":["t:2"]}],' \
               '"after":7,"description":"staging seed"}'
    assert_equal expected, line
  end

  def test_encode_header_defaults_exported_at_to_now
    before = Time.now - 1
    line = EventFile::Header.encode(store: Object.new, query: DcbEventStore::Query.all, after: nil, description: nil)
    record = JSON.parse(line)

    assert_operator Time.iso8601(record["exported_at"]), :>=, before
    assert_equal [[], nil, nil, "Object"], record.values_at("query", "after", "description", "store")
  end

  def test_export_writes_the_header_first_and_it_round_trips
    store = DcbEventStore::InMemoryStore.new
    store.append([DcbEventStore::Event.new(type: "A", tags: ["t:1"])])
    query = DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: ["A"], tags: ["t:1"])])
    io = StringIO.new
    before = Time.now - 1

    EventFile.export(store, io, query: query, after: 0, description: "demo")
    header = EventFile.header(StringIO.new(io.string))

    assert_equal EventFile::FORMAT, header.format
    assert_equal 1, header.version
    assert_operator header.exported_at, :>=, before
    assert_equal DcbEventStore::VERSION, header.gem_version
    assert_equal "DcbEventStore::InMemoryStore", header.store
    assert_equal query, header.query
    assert_equal 0, header.after
    assert_equal "demo", header.description
  end

  def test_header_of_a_file_without_one_or_an_empty_file
    assert_nil EventFile.header(StringIO.new(%({"type":"A"}\n)))
    assert_nil EventFile.header(StringIO.new(""))
  end

  def test_header_skips_leading_blank_lines_and_tolerates_missing_and_unknown_fields
    header = EventFile.header(StringIO.new(%(\n{"format":"dcb_event_store/events","version":1,"future":true}\n)))

    assert_equal [EventFile::FORMAT, 1], [header.format, header.version]
    assert_nil header.exported_at
    assert_nil header.store
    assert_equal DcbEventStore::Query.all, header.query
  end

  def test_header_query_items_may_omit_types_or_tags
    line = '{"format":"dcb_event_store/events","version":1,"query":[{"types":["A"]},{"tags":["t"]}]}'
    items = EventFile.header(StringIO.new(line)).query.items

    assert_equal([[["A"], []], [[], ["t"]]], items.map { |i| [i.event_types, i.tags] })
  end

  def test_rejects_bad_headers
    {
      '{"format":"other","version":1}' => %(line 1: unknown format "other"),
      '{"format":"dcb_event_store/events","version":2}' =>
        "line 1: unsupported format version 2 (this gem reads up to 1)",
      '{"format":"dcb_event_store/events","version":0}' =>
        "line 1: unsupported format version 0 (this gem reads up to 1)",
      '{"format":"dcb_event_store/events","version":"1"}' =>
        %(line 1: unsupported format version "1" (this gem reads up to 1)),
      '{"format":"dcb_event_store/events"}' => "line 1: unsupported format version nil (this gem reads up to 1)"
    }.each do |line, message|
      error = assert_raises(ArgumentError, line) { EventFile.each_event(StringIO.new(line)).to_a }
      assert_equal message, error.message
    end
  end

  def test_a_header_after_the_first_line_is_an_error
    io = StringIO.new(%({"type":"A"}\n{"format":"dcb_event_store/events","version":1}\n))
    error = assert_raises(ArgumentError) { EventFile.each_event(io).to_a }

    assert_equal "line 2: a header is only allowed on the first line", error.message
  end

  def test_each_event_skips_the_header
    io = StringIO.new(%({"format":"dcb_event_store/events","version":1}\n{"type":"A"}\n))
    assert_equal ["A"], EventFile.each_event(io).map(&:type)
  end

  def test_import_reports_the_header
    io = StringIO.new(%({"format":"dcb_event_store/events","version":1,"description":"d"}\n{"type":"A"}\n))
    result = EventFile.import(RecordingStore.new, io)

    assert_equal [1, 1, "d"], [result.read, result.imported, result.header.description]
    assert_nil EventFile.import(RecordingStore.new, lines(1)).header
  end

  # --- import ---

  def lines(count)
    StringIO.new(Array.new(count) { |i| %({"id":"id-#{i}","type":"T#{i}"}\n) }.join)
  end

  def test_import_batches_the_file
    store = RecordingStore.new
    result = EventFile.import(store, lines(5), batch_size: 2)

    assert_equal [2, 2, 1], store.batches.map(&:size)
    assert_equal %w[T0 T1 T2 T3 T4], store.batches.flatten.map(&:type)
    assert_equal [5, 5, 0], [result.read, result.imported, result.skipped]
  end

  def test_import_defaults_to_batches_of_a_thousand
    store = RecordingStore.new
    EventFile.import(store, lines(1001))
    assert_equal [1000, 1], store.batches.map(&:size)
  end

  def test_import_without_batch_size_is_one_batch
    store = RecordingStore.new
    EventFile.import(store, lines(3), batch_size: nil)
    assert_equal [3], store.batches.map(&:size)
  end

  def test_import_counts_skipped_ids
    result = EventFile.import(RecordingStore.new(skip_ids: %w[id-0 id-2]), lines(3))
    assert_equal [3, 1, 2], [result.read, result.imported, result.skipped]
  end

  def test_import_of_an_empty_file_calls_nothing
    store = RecordingStore.new
    result = EventFile.import(store, StringIO.new(""))

    assert_empty store.batches
    assert_equal [0, 0], [result.read, result.imported]
  end

  def test_import_stops_at_a_bad_line_after_committing_earlier_batches
    store = DcbEventStore::InMemoryStore.new
    io = StringIO.new(%({"type":"A"}\n{"type":"B"}\n{"bad":1}\n))

    assert_raises(ArgumentError) { EventFile.import(store, io, batch_size: 2) }
    assert_equal %w[A B], store.read(DcbEventStore::Query.all).map(&:type)
  end
end
