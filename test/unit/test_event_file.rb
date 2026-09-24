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
    assert_equal([1, 2], io.string.lines.map { |l| JSON.parse(l)["sequence_position"] })
    assert io.string.end_with?("\n")
  end

  def test_export_of_an_empty_store
    io = StringIO.new
    assert_equal 0, EventFile.export(DcbEventStore::InMemoryStore.new, io)
    assert_equal "", io.string
  end

  def test_export_filters_by_query_and_position
    store = DcbEventStore::InMemoryStore.new
    store.append(%w[A B A B].map { |type| DcbEventStore::Event.new(type: type) })
    query = DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: ["A"])])

    [[{}, [1, 2, 3, 4]], [{ query: query }, [1, 3]], [{ after: 1 }, [2, 3, 4]],
     [{ query: query, after: 1 }, [3]], [{ after: 0 }, [1, 2, 3, 4]]].each do |options, positions|
      io = StringIO.new
      EventFile.export(store, io, **options)
      assert_equal positions, io.string.lines.map { |l| JSON.parse(l)["sequence_position"] }, options.inspect
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
