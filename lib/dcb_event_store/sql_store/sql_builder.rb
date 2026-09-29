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
    # Namespace); nil, the default, is the plain "events".
    class SqlBuilder
      def initialize(dialect, namespace: nil)
        @dialect = dialect
        @events = Namespace.wrap(namespace).events_table
      end

      ORDERS = { asc: "ASC", desc: "DESC" }.freeze

      # SELECT for reading the event stream matching +query+, optionally only
      # events after +after+ and/or before +before+. +order+ (:asc/:desc) sets
      # the sequence_position ordering -- :desc for a backwards read;
      # +limit+/+offset+ page the result (limit per page of a store read,
      # offset for the read-only browser). Defaults reproduce the store's
      # ascending full-stream read.
      def read_sql(query, after: nil, before: nil, order: :asc, limit: nil, offset: nil) # rubocop:disable Metrics/ParameterLists
        direction = ORDERS.fetch(order) { raise ArgumentError, "order must be :asc or :desc" }
        where, params = where_clause(query, after, before)
        sql = "SELECT * FROM #{@events}"
        sql += " WHERE #{where}" if where
        sql += " ORDER BY sequence_position #{direction}"
        sql += " LIMIT #{Integer(limit)}" if limit
        sql += " OFFSET #{Integer(offset)}" if offset
        [sql, params]
      end

      # SELECT COUNT(*) used to evaluate an AppendCondition (and to total the
      # browser): how many existing events match +query+ after +after+.
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

      # The item clauses OR-ed together (none for a match-all query), then
      # the position bounds AND-ed on, the items' parameters first.
      def where_clause(query, after, before = nil)
        params = []
        where = query.items.map { |item| item_clause(item, params, after, before) }.join(" OR ") unless query.match_all?
        bounds = []
        bounds << @dialect.after_clause(params, after) if after
        bounds << @dialect.before_clause(params, before) if before
        return [where, params] if bounds.empty?

        bounds = bounds.join(" AND ")
        [where ? "(#{where}) AND #{bounds}" : bounds, params]
      end

      def item_clause(item, params, after, before)
        parts = []
        parts << @dialect.type_in(params, item.event_types) unless item.event_types.empty?
        parts << @dialect.tags_contain(params, item.tags, after: after, before: before) unless item.tags.empty?

        "(#{parts.join(' AND ')})"
      end
    end
  end
end
