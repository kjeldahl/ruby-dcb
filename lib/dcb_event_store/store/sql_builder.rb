module DcbEventStore
  class Store
    # Builds the SQL strings and bind-parameter arrays the Store executes.
    # Pure: every method is a function of its arguments (a Query, an
    # AppendCondition's parts, or the events to insert) and the injected
    # PgArrayCodec. No connection, no I/O — fast to unit and mutation test.
    #
    # Each builder returns a [sql, params] pair (or a values clause / params
    # pair) ready to hand to PG#exec_params.
    class SqlBuilder
      def initialize(codec)
        @codec = codec
      end

      # SELECT for reading the event stream matching +query+, optionally only
      # events after +after+, ordered by ascending sequence position.
      def read_sql(query, after:)
        where, params = where_clause(query, after)
        sql = "SELECT * FROM events"
        sql += " WHERE #{where}" if where
        sql += " ORDER BY sequence_position ASC"
        [sql, params]
      end

      # SELECT COUNT(*) used to evaluate an AppendCondition: how many existing
      # events match +query+ after +after+.
      def condition_sql(query, after)
        where, params = where_clause(query, after)
        sql = where ? "SELECT COUNT(*) FROM events WHERE #{where}" : "SELECT COUNT(*) FROM events"
        [sql, params]
      end

      # The "(VALUES ...)" row fragments and their bind parameters for inserting
      # +events+. +param_offset+ is the number of bind parameters already
      # consumed by a preceding clause, so the placeholders continue from there.
      def values_clause(events, param_offset)
        value_rows = []
        insert_params = []
        events.each do |event|
          offset = param_offset + insert_params.size
          value_rows << "($#{offset + 1}::uuid, $#{offset + 2}::text, $#{offset + 3}::jsonb, " \
                        "$#{offset + 4}::text[], $#{offset + 5}::uuid, $#{offset + 6}::uuid, $#{offset + 7}::integer)"
          insert_params.push(
            event.id, event.type, JSON.generate(event.data),
            @codec.encode(event.tags),
            event.causation_id, event.correlation_id, 1
          )
        end
        [value_rows, insert_params]
      end

      private

      def where_clause(query, after)
        return match_all_where(after) if query.match_all?

        params = []
        clauses = query.items.filter_map { |item| item_clause(item, params) }
        where = clauses.join(" OR ")

        if after
          params << after
          where = "(#{where}) AND sequence_position > $#{params.size}"
        end

        [where, params]
      end

      def match_all_where(after)
        return ["sequence_position > $1", [after]] if after

        [nil, []]
      end

      def item_clause(item, params)
        parts = []
        unless item.event_types.empty?
          params << @codec.encode(item.event_types)
          parts << "type = ANY($#{params.size}::text[])"
        end
        unless item.tags.empty?
          params << @codec.encode(item.tags)
          parts << "tags @> $#{params.size}::text[]"
        end
        return if parts.empty?

        "(#{parts.join(' AND ')})"
      end
    end
  end
end
