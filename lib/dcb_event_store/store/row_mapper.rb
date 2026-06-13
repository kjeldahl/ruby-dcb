require "json"
require "time"

module DcbEventStore
  class Store
    # Maps PostgreSQL result rows (string-keyed, all-text columns) into
    # SequencedEvent objects, applying the optional upcaster on read.
    # Pure given a row hash and event — no connection — so it can be unit and
    # mutation tested with plain hashes.
    class RowMapper
      def initialize(codec, upcaster)
        @codec = codec
        @upcaster = upcaster
      end

      # Builds a SequencedEvent from a full event row read back from the store,
      # decoding the stored JSON/tags and upcasting the payload if configured.
      def to_sequenced_event(row)
        type = row["type"]
        data = JSON.parse(row["data"], symbolize_names: true)
        version = row["schema_version"].to_i

        data, version = @upcaster.upcast(type, data, version) if @upcaster

        SequencedEvent.new(
          sequence_position: row["sequence_position"].to_i,
          type: type,
          data: data,
          tags: @codec.parse(row["tags"]),
          created_at: Time.parse(row["created_at"]),
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
          sequence_position: row["sequence_position"].to_i,
          type: event.type,
          data: event.data,
          tags: event.tags,
          created_at: Time.parse(row["created_at"]),
          id: event.id,
          causation_id: event.causation_id,
          correlation_id: event.correlation_id,
          schema_version: 1
        )
      end
    end
  end
end
