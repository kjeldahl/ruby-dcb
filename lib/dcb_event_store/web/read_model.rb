module DcbEventStore
  module Web
    # Read-only query object for the event browser. Wraps a raw +pg+ connection
    # and composes the store's pure SqlBuilder + RowMapper, adding the shapes the
    # Store API doesn't expose: total count, head position, newest-first paging,
    # the distinct type list, and single-event lookup. No writes - the browser
    # only ever reads.
    class ReadModel
      def initialize(conn, upcaster: nil)
        @conn = conn
        @codec = PgArrayCodec.new
        @sql = Store::SqlBuilder.new(@codec)
        @mapper = Store::RowMapper.new(@codec, upcaster)
      end

      # Total events matching +query+ (defaults to the whole stream).
      def count(query = Query.all)
        sql, params = @sql.count_sql(query)
        @conn.exec_params(sql, params).getvalue(0, 0).to_i
      end

      # Highest sequence_position in the store, or nil when empty.
      def head_position
        @conn.exec("SELECT max(sequence_position) FROM events").getvalue(0, 0)&.to_i
      end

      # A page of events matching +query+, newest first.
      def page(query: Query.all, limit: 50, offset: 0)
        sql, params = @sql.read_sql(query, after: nil, order: :desc, limit: limit, offset: offset)
        @conn.exec_params(sql, params).map { |row| @mapper.to_sequenced_event(row) }
      end

      # Distinct event types present, sorted - powers the filter dropdown.
      def event_types
        @conn.exec("SELECT DISTINCT type FROM events ORDER BY type").map { |row| row["type"] }
      end

      # A single event by sequence_position, or nil when absent.
      def find(position)
        result = @conn.exec_params("SELECT * FROM events WHERE sequence_position = $1", [Integer(position)])
        return nil if result.ntuples.zero?

        @mapper.to_sequenced_event(result.first)
      end
    end
  end
end
