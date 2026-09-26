require "json"
require "pathname"
require "securerandom"
require "time"

module DcbEventStore
  # Exports events to, and imports them from, JSON Lines: one event per
  # line, the format for seeding a store, backing one up or moving events
  # between backends.
  #
  #   {"sequence_position":1,"id":"…","type":"CourseDefined","tags":["course:c1"],
  #    "data":{"capacity":10},"causation_id":null,"correlation_id":null,
  #    "schema_version":1,"created_at":"2026-09-24T10:00:00.123456Z"}
  #
  # An export writes every field. An import needs only "type": a missing
  # "data" is {}, "tags" [], "schema_version" 1, "created_at" the time of the
  # import and "id" a fresh UUID -- so a hand-written seed file can be short,
  # but only lines carrying an id are skipped when imported twice (the
  # stores skip ids they hold). "sequence_position" is informational: the
  # importing store assigns its own, in file order. Unknown keys are an
  # error, so a typo does not silently drop a field.
  #
  # An export starts with a header line saying what the file holds and where
  # it came from (the "format" key is what marks it):
  #
  #   {"format":"dcb_event_store/events","version":1,
  #    "exported_at":"2026-09-26T08:00:00.000000Z","gem_version":"0.4.2",
  #    "store":"DcbEventStore::PostgresStore",
  #    "query":[{"types":["CourseDefined"],"tags":[]}],"after":null,
  #    "description":"staging seed"}
  #
  # The header is optional on import, so a seed file can be events alone;
  # when present it must be the first line, its format must match and its
  # version be one this gem reads. Keys it does not know are ignored, so a
  # later gem can add fields without a version bump. "query" is the export's
  # filter ([] for everything), "after" its position bound.
  #
  # Exports read through the store, so a store with an upcaster exports the
  # upcast payload under the upcast schema_version, and an import writes them
  # back as such. Imports go through the store's #import, which keeps
  # created_at and schema_version and checks no AppendCondition: the file is
  # trusted.
  module EventFile
    KEYS = %w[sequence_position id type tags data causation_id correlation_id schema_version created_at].freeze
    DEFAULT_BATCH_SIZE = 1000
    FORMAT = "dcb_event_store/events".freeze
    # The header version this gem writes, and the newest it reads.
    FORMAT_VERSION = 1

    # What an import did: events read, and events written (the rest were ids
    # the store already held), plus the file's header (nil without one).
    ImportResult = Data.define(:read, :imported, :header) do
      def skipped = read - imported
    end

    # One line (no newline) for +event+, a SequencedEvent.
    def self.encode(event)
      JSON.generate(
        "sequence_position" => event.sequence_position,
        "id" => event.id,
        "type" => event.type,
        "tags" => event.tags,
        "data" => event.data,
        "causation_id" => event.causation_id,
        "correlation_id" => event.correlation_id,
        "schema_version" => event.schema_version,
        "created_at" => event.created_at&.getutc&.iso8601(6)
      )
    end

    # The SequencedEvent one line describes, defaults filled in. Raises
    # ArgumentError on a line that is not an event.
    def self.decode(line)
      event_from(parse_object(line))
    end

    # The header of +source+ (see #each_event), nil when its first line is an
    # event.
    def self.header(source)
      entry = enum_for(:each_entry, source).first
      entry if entry.instance_of?(Header)
    end

    def self.event_from(record)
      unknown = record.keys - KEYS
      raise ArgumentError, "unknown key(s): #{unknown.join(', ')}" unless unknown.empty?
      raise ArgumentError, "missing \"type\"" if record["type"].to_s.empty?

      SequencedEvent.new(
        sequence_position: record["sequence_position"],
        type: record.fetch("type").to_s,
        data: symbolize(record["data"] || {}),
        tags: Array(record["tags"]).map(&:to_s),
        created_at: parse_time(record["created_at"]),
        id: record["id"] || SecureRandom.uuid,
        causation_id: record["causation_id"],
        correlation_id: record["correlation_id"],
        schema_version: record["schema_version"] || 1
      )
    end
    private_class_method :event_from

    def self.parse_object(line)
      record = JSON.parse(line)
      raise ArgumentError, "expected a JSON object, got #{record.class}" unless record.instance_of?(Hash)

      record
    rescue JSON::ParserError => e
      raise ArgumentError, "invalid JSON: #{e}"
    end
    private_class_method :parse_object

    # Time.iso8601 of +value+, nil for nil.
    def self.parse_time(value)
      value && Time.iso8601(value)
    end

    # Writes a header, then the events of +store+ matching +query+ (after
    # position +after+), to +target+: a path (String or Pathname), or an IO.
    # +description+ goes into the header as it is. Returns the number of
    # events written.
    def self.export(store, target, query: Query.all, after: nil, description: nil)
      events = store.read_from(query, after: after)
      count = 0
      writing(target) do |io|
        io.puts(Header.encode(store: store, query: query, after: after, description: description))
        events.each do |event|
          io.puts(encode(event))
          count += 1
        end
      end
      count
    end

    # Lazily decodes the events in +source+: a path (String), or anything
    # with #each_line (an IO, StringIO, Pathname). The header is checked and
    # skipped, blank lines are skipped; a bad line raises ArgumentError
    # naming its line number.
    def self.each_event(source)
      return enum_for(:each_event, source) unless block_given?

      each_entry(source) { |entry| yield entry if entry.instance_of?(SequencedEvent) }
    end

    # Yields the Header (first line only) and the SequencedEvents of +source+.
    def self.each_entry(source)
      lines = case source
              when String then File.foreach(source)
              else source.each_line
              end
      first = true
      lines.with_index(1) do |line, number|
        next unless line.match?(/\S/)

        yield entry_from(line, first)
        first = false
      rescue ArgumentError => e
        raise ArgumentError, "line #{number}: #{e}"
      end
    end
    private_class_method :each_entry

    def self.entry_from(line, first)
      record = parse_object(line)
      return event_from(record) unless record.key?("format")
      raise ArgumentError, "a header is only allowed on the first line" unless first

      Header.from_record(record)
    end
    private_class_method :entry_from

    # Imports the events in +source+ (see #each_event) into +store+, in
    # file order, +batch_size+ events per store transaction (nil: the whole
    # file in one). A failing batch rolls back alone; since stored ids are
    # skipped, running the import again resumes where it stopped.
    def self.import(store, source, batch_size: DEFAULT_BATCH_SIZE)
      header = nil
      events = Enumerator.new do |yielder|
        each_entry(source) { |entry| entry.instance_of?(Header) ? header = entry : yielder << entry }
      end
      read = 0
      imported = 0
      batches = batch_size ? events.each_slice(batch_size) : [events.to_a]
      batches.each do |batch|
        read += batch.size
        imported += store.import(batch).size
      end
      ImportResult.new(read: read, imported: imported, header: header)
    end

    # A String or Pathname is a path to write, always a file (File.open,
    # never Kernel#open, which would run a "|command"); anything else (an IO,
    # StringIO, $stdout) is written to as it is.
    def self.writing(target, &)
      case target
      when String, Pathname then File.open(target, "w", &)
      else yield target
      end
    end
    private_class_method :writing

    def self.symbolize(value)
      case value
      when Hash then value.to_h { |k, v| [k.to_sym, symbolize(v)] }
      when Array then value.map { |v| symbolize(v) }
      else value
      end
    end
    private_class_method :symbolize
  end
end

require_relative "event_file/header"
