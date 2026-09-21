module DcbEventStore
  class SqlStore
    # Builds the SQL strings and bind-parameter arrays a SqlStore executes.
    # Pure: every method is a function of its arguments (a Query, an
    # AppendCondition's parts, or the events to insert) and the injected
    # dialect. No connection, no I/O — fast to unit and mutation test.
    #
    # The statement shapes (SELECT, COUNT, VALUES rows) live here; everything
    # backend-specific about them — placeholder syntax, matching operators,
    # column casts, list encoding — comes from the dialect.
    #
    # Each builder returns a [sql, params] pair (or a values clause / params
    # pair) ready to hand to the driver.
    #
    # +namespace+ names the events table the statements read (see
    # Namespace); the default is the plain "events".
    class SqlBuilder
      def initialize(dialect, namespace: Namespace::DEFAULT)
        @dialect = dialect
        @events = Namespace.wrap(namespace).events_table
      end

      # SELECT for reading the event stream matching +query+, optionally only
      # events after +after+, ordered by ascending sequence position.
      def read_sql(query, after:)
        where, params = where_clause(query, after)
        sql = "SELECT * FROM #{@events}"
        sql += " WHERE #{where}" if where
        sql += " ORDER BY sequence_position ASC"
        [sql, params]
      end

      # SELECT COUNT(*) used to evaluate an AppendCondition: how many existing
      # events match +query+ after +after+.
      def condition_sql(query, after)
        where, params = where_clause(query, after)
        sql = where ? "SELECT COUNT(*) FROM #{@events} WHERE #{where}" : "SELECT COUNT(*) FROM #{@events}"
        [sql, params]
      end

      # The "(VALUES ...)" row fragments and their bind parameters for inserting
      # +events+. +param_offset+ is the number of bind parameters already
      # consumed by a preceding clause, so the placeholders continue from there:
      # the dialect numbers them off the array it appends to, which starts out
      # padded to the offset and is unpadded again on the way out.
      def values_clause(events, param_offset)
        params = Array.new(param_offset)
        value_rows = events.map { |event| @dialect.insert_row(params, event) }
        [value_rows, params.drop(param_offset)]
      end

      private

      def where_clause(query, after)
        return match_all_where(after) if query.match_all?

        params = []
        clauses = query.items.filter_map { |item| item_clause(item, params, after) }
        where = clauses.join(" OR ")
        where = "(#{where}) AND #{@dialect.after_clause(params, after)}" if after

        [where, params]
      end

      def match_all_where(after)
        return [nil, []] unless after

        params = []
        [@dialect.after_clause(params, after), params]
      end

      def item_clause(item, params, after)
        parts = []
        parts << @dialect.type_in(params, item.event_types) unless item.event_types.empty?
        parts << @dialect.tags_contain(params, item.tags, after: after) unless item.tags.empty?
        return if parts.empty?

        "(#{parts.join(' AND ')})"
      end
    end
  end
end
