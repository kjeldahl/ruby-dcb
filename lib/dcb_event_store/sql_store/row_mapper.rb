require "json"
require_relative "timestamp"

module DcbEventStore
  class SqlStore
    # Maps SQL result rows (string-keyed) into SequencedEvent objects, applying
    # the optional upcaster on read. The injected dialect decodes the stored tag
    # list; the remaining cells are taken as they come, which differs per
    # driver: PostgreSQL hands back every column as text, other drivers return
    # already-typed values.
    # Pure given a row hash and event — no connection — so it can be unit and
    # mutation tested with plain hashes.
    class RowMapper
      def initialize(dialect, upcaster)
        @dialect = dialect
        @upcaster = upcaster
      end

      # Builds a SequencedEvent from a full event row read back from the store,
      # decoding the stored JSON/tags and upcasting the payload if configured.
      def to_sequenced_event(row)
        type = row["type"]
        data = JSON.parse(row["data"], symbolize_names: true)
        version = Integer(row["schema_version"])

        data, version = @upcaster.upcast(type, data, version) if @upcaster

        SequencedEvent.new(
          sequence_position: Integer(row["sequence_position"]),
          type: type,
          data: data,
          tags: @dialect.decode_list(row["tags"]),
          created_at: timestamp(row["created_at"]),
          id: row["event_id"],
          causation_id: row["causation_id"],
          correlation_id: row["correlation_id"],
          schema_version: version
        )
      end

      # Builds a SequencedEvent for a just-inserted event, taking the payload
      # from the original +event+ and only the generated columns (position,
      # timestamp) from the RETURNING +row+.
      def to_appended_event(event, row)
        SequencedEvent.new(
          sequence_position: Integer(row["sequence_position"]),
          type: event.type,
          data: event.data,
          tags: event.tags,
          created_at: timestamp(row["created_at"]),
          id: event.id,
          causation_id: event.causation_id,
          correlation_id: event.correlation_id,
          schema_version: 1
        )
      end

      private

      # Timestamp cells arrive either as text to parse or as a Time the driver
      # already built.
      def timestamp(value)
        return value if value.is_a?(Time)

        Timestamp.parse(value)
      end
    end
  end
end
