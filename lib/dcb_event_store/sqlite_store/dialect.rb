require "json"

module DcbEventStore
  class SqliteStore
    # The SQLite side of the SQL that SqlBuilder assembles, with the same
    # interface as PostgresStore::Dialect: placeholder syntax, the type/tag
    # matching clauses, the insert statements and the list encoding tags are
    # stored in.
    #
    # Where PostgreSQL matches against array columns, SQLite matches against
    # a JSON list expanded with json_each (so a clause spends a fixed number
    # of bind parameters whatever the list length, just like PG's = ANY) and
    # against the event_tags index table for containment.
    #
    # Pure: no connection, no I/O.
    class Dialect
      # Bind parameters are positional in SQLite, so a placeholder is the same
      # "?" wherever it appears; the index the interface passes is unused.
      def placeholder(_index)
        "?"
      end

      # Matches events whose type is one of +types+.
      def type_in(params, types)
        params << encode_list(types)
        "type IN (SELECT value FROM json_each(?))"
      end

      # Matches events carrying all of +tags+, by counting how many of the
      # wanted tags each event has in the index table. The count must be
      # compared against the number of *distinct* tags, so the list is
      # deduplicated before it is bound.
      def tags_contain(params, tags)
        wanted = tags.uniq
        params << encode_list(wanted)
        params << wanted.size
        "sequence_position IN (SELECT sequence_position FROM event_tags " \
          "WHERE tag IN (SELECT value FROM json_each(?)) " \
          "GROUP BY sequence_position HAVING COUNT(*) = ?)"
      end

      # Matches events stored after sequence position +after+.
      def after_clause(params, after)
        params << after
        "sequence_position > ?"
      end

      # One "(...)" row fragment for a multi-row INSERT ... VALUES, appending
      # the event's parameters to +params+. No casts: SQLite takes the bound
      # values as they are.
      def insert_row(params, event)
        params.concat(insert_params(event))
        "(?, ?, ?, ?, ?, ?, ?)"
      end

      # Single-row insert of one event, skipping an id that is already stored
      # and returning the generated columns. Takes #insert_params.
      def insert_sql
        <<~SQL
          INSERT INTO events (event_id, type, data, tags, causation_id, correlation_id, schema_version)
          VALUES (?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(event_id) DO NOTHING
          RETURNING sequence_position, created_at
        SQL
      end

      # Insert of one row into the tag index table, taking the tag and the
      # sequence position the insert above returned.
      def insert_tag_sql
        "INSERT INTO event_tags (tag, sequence_position) VALUES (?, ?)"
      end

      # The bind parameters of one event, in the column order used by
      # #insert_sql and #insert_row.
      def insert_params(event)
        [event.id, event.type, JSON.generate(event.data), encode_list(event.tags),
         event.causation_id, event.correlation_id, 1]
      end

      # Tag/type lists travel as JSON arrays of strings: the format the tags
      # column stores and json_each expands.
      def encode_list(arr)
        JSON.generate(arr.map(&:to_s))
      end

      def decode_list(str)
        return [] if str.nil?

        JSON.parse(str)
      end
    end
  end
end
