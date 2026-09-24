require "json"
require "time"
require_relative "../sql_store/timestamp"

module DcbEventStore
  class PostgresStore
    # The PostgreSQL side of the SQL that SqlBuilder assembles: placeholder
    # syntax, the type/tag matching operators, the column casts an INSERT needs
    # and the list encoding tags are stored in. A second backend supplies its
    # own dialect with the same interface, and SqlBuilder stays unchanged.
    #
    # The clause builders take the bind-parameter array being assembled, push
    # the parameters they need onto it and return the SQL fragment referring to
    # them, so a dialect is free to spend more (or fewer) parameters per clause.
    #
    # Pure: no connection, no I/O.
    class Dialect
      def initialize
        @codec = ArrayCodec.new
      end

      # Bind-parameter reference for the +index+th parameter (1-based).
      def placeholder(index)
        "$#{index}"
      end

      # Matches events whose type is one of +types+.
      def type_in(params, types)
        params << encode_list(types)
        "type = ANY(#{placeholder(params.size)}::text[])"
      end

      # Matches events carrying all of +tags+. +after+ is accepted for
      # interface parity with the SQLite dialect and not needed here: the GIN
      # lookup is by tag and the position bound is applied by the outer
      # clause.
      def tags_contain(params, tags, after: nil) # rubocop:disable Lint/UnusedMethodArgument
        params << encode_list(tags)
        "tags @> #{placeholder(params.size)}::text[]"
      end

      # Matches events stored after sequence position +after+.
      def after_clause(params, after)
        params << after
        "sequence_position > #{placeholder(params.size)}"
      end

      # One "(...)" row fragment for a multi-row INSERT ... VALUES, appending
      # the event's parameters to +params+. The casts are explicit because the
      # values come from a VALUES list, where PostgreSQL cannot infer the
      # column types.
      def insert_row(params, event)
        offset = params.size
        params.concat(insert_params(event))
        "(#{placeholder(offset + 1)}::uuid, #{placeholder(offset + 2)}::text, " \
          "#{placeholder(offset + 3)}::jsonb, #{placeholder(offset + 4)}::text[], " \
          "#{placeholder(offset + 5)}::uuid, #{placeholder(offset + 6)}::uuid, " \
          "#{placeholder(offset + 7)}::integer)"
      end

      # Single-row insert of one event, skipping an id that is already stored
      # and returning the generated columns. Takes #insert_params.
      def insert_sql
        <<~SQL
          INSERT INTO events (event_id, type, data, tags, causation_id, correlation_id, schema_version)
          VALUES ($1, $2, $3::jsonb, $4::text[], $5, $6, $7)
          ON CONFLICT (event_id) DO NOTHING
          RETURNING sequence_position, created_at
        SQL
      end

      # The bind parameters of one event, in the column order used by
      # #insert_sql and #insert_row.
      def insert_params(event)
        [event.id, event.type, JSON.generate(event.data), encode_list(event.tags),
         event.causation_id, event.correlation_id, 1]
      end

      # Single-row insert of one imported event: #insert_sql plus the
      # schema_version and created_at the export carried (now() when nil).
      # Takes #import_params.
      def import_sql
        <<~SQL
          INSERT INTO events (event_id, type, data, tags, causation_id, correlation_id, schema_version, created_at)
          VALUES ($1, $2, $3::jsonb, $4::text[], $5, $6, $7, COALESCE($8::timestamptz, now()))
          ON CONFLICT (event_id) DO NOTHING
          RETURNING sequence_position, created_at
        SQL
      end

      def import_params(event)
        [*insert_params(event).take(6), event.schema_version || 1, encode_timestamp(event.created_at)]
      end

      # ISO 8601 with microseconds, TIMESTAMPTZ's resolution.
      def encode_timestamp(time)
        time&.iso8601(6)
      end

      # Tag/type lists travel as PostgreSQL text array literals.
      def encode_list(arr)
        @codec.encode(arr)
      end

      def decode_list(str)
        @codec.parse(str)
      end

      # The created_at cell. The store puts a TIMESTAMPTZ decoder on its
      # connection (see PostgresStore::RESULT_TYPE_MAP), so the driver has
      # normally built the Time already; text still arrives from a connection
      # whose type map was replaced, or from a column typed TIMESTAMP rather
      # than TIMESTAMPTZ.
      def decode_timestamp(value)
        return value if value.is_a?(Time)

        SqlStore::Timestamp.parse(value)
      end
    end
  end
end
