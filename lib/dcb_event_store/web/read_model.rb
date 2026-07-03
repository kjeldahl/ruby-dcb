module DcbEventStore
  module Web
    # Read-only query object for the event browser. Wraps a raw +pg+ connection
    # and composes the store's pure SqlBuilder + RowMapper, adding the shapes the
    # Store API doesn't expose: total count, head position, newest-first paging,
    # the distinct type list, and single-event lookup, plus the namespace's
    # projection snapshots. One instance reads one namespace (see Namespace):
    # its events table and its snapshots table. No writes - the browser only
    # ever reads.
    class ReadModel
      # A row of the snapshots table. +state+ is nil in listings, which leave
      # the (possibly large) JSON out.
      SnapshotRecord = Data.define(:key, :position, :updated_at, :state)

      # Names of the namespaces that have an events table in the connection's
      # current schema, the default (nil) first. A table counts when it is
      # called "events" or "<name>_events" and has the events columns.
      NAMESPACES_SQL = <<~SQL.freeze
        SELECT table_name FROM information_schema.columns
        WHERE table_schema = current_schema()
          AND table_name ~ '^([a-z][a-z0-9_]*_)?events$'
          AND column_name IN ('sequence_position', 'event_id', 'type', 'data', 'tags')
        GROUP BY table_name HAVING count(*) = 5
      SQL

      def self.namespaces(conn)
        tables = conn.exec(NAMESPACES_SQL).map { |row| row["table_name"] }
        tables.filter_map { |table| namespace_of(table) }.map(&:first).sort_by(&:to_s)
      end

      # [nil] for "events" (the default namespace), [name] for "<name>_events",
      # nil for a table whose prefix is not a valid namespace name.
      def self.namespace_of(table)
        return [nil] if table == "events"

        [Namespace.new(table.delete_suffix("_events")).name]
      rescue ArgumentError
        nil
      end
      private_class_method :namespace_of

      def initialize(conn, upcaster: nil, namespace: nil)
        @conn = conn
        @namespace = Namespace.wrap(namespace)
        @events = @namespace.events_table
        @snapshots = @namespace.snapshots_table
        @dialect = PostgresStore::Dialect.new(namespace: @namespace)
        @sql = SqlStore::SqlBuilder.new(@dialect, namespace: @namespace)
        @mapper = SqlStore::RowMapper.new(@dialect, upcaster)
      end

      # Total events matching +query+ (defaults to the whole stream).
      def count(query = Query.all)
        sql, params = @sql.condition_sql(query, nil)
        @conn.exec_params(sql, params).getvalue(0, 0).to_i
      end

      # Highest sequence_position in the store, or nil when empty.
      def head_position
        @conn.exec("SELECT max(sequence_position) FROM #{@events}").getvalue(0, 0)&.to_i
      end

      # A page of events matching +query+, newest first.
      def page(query: Query.all, limit: 50, offset: 0)
        sql, params = @sql.read_sql(query, after: nil, order: :desc, limit: limit, offset: offset)
        @conn.exec_params(sql, params).map { |row| @mapper.to_sequenced_event(row) }
      end

      # Distinct event types present, sorted - powers the filter dropdown.
      def event_types
        @conn.exec("SELECT DISTINCT type FROM #{@events} ORDER BY type").map { |row| row["type"] }
      end

      # A single event by sequence_position, or nil when absent.
      def find(position)
        result = @conn.exec_params("SELECT * FROM #{@events} WHERE sequence_position = $1", [Integer(position)])
        return nil if result.ntuples.zero?

        @mapper.to_sequenced_event(result.first)
      end

      # Whether the namespace's snapshots table exists (a database whose schema
      # predates snapshots has none).
      def snapshots?
        !@conn.exec_params("SELECT to_regclass($1)", [@snapshots]).getvalue(0, 0).nil?
      end

      # Snapshots whose key contains +match+ (all when empty), most recently
      # written first, without their state.
      def snapshot_page(match: "", limit: 50, offset: 0)
        @conn.exec_params(
          "SELECT key, position, updated_at FROM #{@snapshots} WHERE strpos(key, $1) > 0 " \
          "ORDER BY updated_at DESC, key LIMIT $2 OFFSET $3",
          [match, Integer(limit), Integer(offset)]
        ).map { |row| snapshot_record(row) }
      end

      def snapshot_count(match: "")
        @conn.exec_params("SELECT count(*) FROM #{@snapshots} WHERE strpos(key, $1) > 0", [match])
             .getvalue(0, 0).to_i
      end

      # One snapshot by key, state included, or nil when absent.
      def find_snapshot(key)
        result = @conn.exec_params("SELECT key, position, updated_at, state FROM #{@snapshots} WHERE key = $1", [key])
        return nil if result.ntuples.zero?

        snapshot_record(result.first)
      end

      private

      def snapshot_record(row)
        state = row["state"]
        SnapshotRecord.new(
          key: row["key"],
          position: Integer(row["position"]),
          updated_at: @dialect.decode_timestamp(row["updated_at"]),
          state: state && JSON.parse(state, symbolize_names: true)
        )
      end
    end
  end
end
