require "json"
require "time"

module DcbEventStore
  module EventFile
    # The first line of an export, decoded: what the file holds and where it
    # came from. query is a Query, exported_at a Time; every field but format
    # and version may be nil in a hand-written header.
    Header = Data.define(:format, :version, :exported_at, :gem_version, :store, :query, :after, :description) do
      # The header line (no newline) for an export of +store+ matching
      # +query+ after +after+.
      def self.encode(store:, query:, after:, description:, exported_at: Time.now)
        JSON.generate(
          "format" => FORMAT,
          "version" => FORMAT_VERSION,
          "exported_at" => exported_at.getutc.iso8601(6),
          "gem_version" => VERSION,
          "store" => store.class.name,
          "query" => query.items.map { |item| { "types" => item.event_types, "tags" => item.tags } },
          "after" => after,
          "description" => description
        )
      end

      # The Header a parsed header line describes. Raises ArgumentError on a
      # format other than FORMAT or a version this gem cannot read; keys it
      # does not know are ignored.
      def self.from_record(record)
        raise ArgumentError, "unknown format #{record['format'].inspect}" unless record["format"] == FORMAT

        version = record["version"]
        unless version.is_a?(Integer) && version.between?(1, FORMAT_VERSION)
          raise ArgumentError, "unsupported format version #{version.inspect} (this gem reads up to #{FORMAT_VERSION})"
        end

        new(
          format: FORMAT, version: version,
          exported_at: EventFile.parse_time(record["exported_at"]),
          gem_version: record["gem_version"], store: record["store"],
          query: Query.new(Array(record["query"]).map { |item| query_item(item) }),
          after: record["after"], description: record["description"]
        )
      end

      def self.query_item(item)
        QueryItem.new(event_types: item["types"], tags: item["tags"])
      end
      private_class_method :query_item
    end
  end
end
