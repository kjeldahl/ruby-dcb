require_relative "sql_store"

module DcbEventStore
  # PostgreSQL-backed store: the SqlStore hooks implemented against a live
  # PG connection.
  #
  # Appends serialize on per-tag advisory locks (see LockKeys) covering the
  # tags they write and the tags their condition names, so appends touching
  # disjoint tags still run in parallel, and subscribers are woken through
  # LISTEN/NOTIFY rather than polling.
  #
  # The store takes the connection over: it is the store's alone, and must
  # not be shared with application queries. #subscribe puts it in LISTEN for
  # as long as it runs, appends hold advisory locks on it, and #initialize
  # replaces its result type map (below) -- so a caller issuing its own
  # queries on the same connection would see them decoded by the store's map
  # and would race the store's transactions. Give the application its own
  # connection, or give the store one per thread.
  #
  # +namespace:+ selects which event log in the database the store works on
  # (see Namespace): its tables, its NOTIFY channel and its advisory-lock key
  # space are all its own, so stores in different namespaces neither see nor
  # wait for each other. The schema must have been installed for that
  # namespace (Schema.create!(conn, namespace: ...)).
  class PostgresStore < SqlStore
    # Decoders the store installs on its connection. Only created_at is
    # touched: TIMESTAMPTZ (OID 1184) comes back as a Time the driver built
    # in C, which saves the row mapper a parse on every row read. Everything
    # else falls through to text, which is what RowMapper and Dialect expect
    # -- decoding jsonb and text[] here too would hand them Ruby objects they
    # would only have to undo.
    def self.result_type_map
      map = PG::TypeMapByOid.new
      map.add_coder(PG::TextDecoder::TimestampWithTimeZone.new(oid: 1184, format: 0))
      map.default_type_map = PG::TypeMapAllStrings.new
      map
    end

    def initialize(conn, upcaster: nil, subscribe_instrumentation: :event, namespace: nil)
      super(upcaster: upcaster, subscribe_instrumentation: subscribe_instrumentation, namespace: namespace)
      @conn = conn
      @conn.type_map_for_results = self.class.result_type_map
      @dialect = Dialect.new(namespace: @namespace)
      @sql = SqlBuilder.new(@dialect, namespace: @namespace)
      @row_mapper = RowMapper.new(@dialect, @upcaster)
    end

    private

    def fetch_batch(query, after:, limit:)
      sql, params = @sql.read_sql(query, after: after)
      @conn.exec_params("#{sql} LIMIT #{limit}", params).to_a
    end

    def max_position
      value = @conn.exec("SELECT max(sequence_position) FROM #{@namespace.events_table}")[0]["max"]
      value && Integer(value)
    end

    # The global key first, then the tag keys in sorted order, so every
    # append acquires in one order (see LockKeys). Every key is shifted by
    # the namespace's offset, which keeps namespaces from locking each other
    # out and leaves the default namespace's keys untouched.
    def acquire_locks!(events, condition)
      locks = LockKeys.for(events, condition)
      offset = @namespace.lock_offset
      fn = locks.global == :exclusive ? "pg_advisory_xact_lock" : "pg_advisory_xact_lock_shared"
      @conn.exec("SELECT #{fn}(#{offset + LockKeys::APPEND_LOCK_KEY})")
      return if locks.tags.empty?

      keys = locks.tags.map { |key| offset + key }
      @conn.exec_params("SELECT acquire_sorted_advisory_locks($1::bigint[])", ["{#{keys.join(',')}}"])
    end

    def count_matching(query, after)
      sql, params = @sql.condition_sql(query, after)
      @conn.exec_params(sql, params)[0]["count"].to_i
    end

    # PostgreSQL does the conditional append in a single statement: the CTE
    # evaluates the condition and the INSERT ... SELECT only writes rows when
    # the CTE found no conflict, so one round trip covers check and insert.
    # An empty RETURNING means either a conflict or that every event was a
    # duplicate id, which the follow-up count tells apart.
    def append_with_condition(events, condition)
      cond_sql, cond_params = @sql.condition_sql(condition.fail_if_events_match, condition.after)
      value_rows, insert_params = @sql.values_clause(events, cond_params.size)

      result = @conn.exec_params(
        <<~SQL,
          WITH cond AS (#{cond_sql})
          INSERT INTO #{@namespace.events_table} (event_id, type, data, tags, causation_id, correlation_id, schema_version)
          SELECT v.* FROM (VALUES #{value_rows.join(', ')})
            AS v(event_id, type, data, tags, causation_id, correlation_id, schema_version)
          WHERE NOT EXISTS (SELECT 1 FROM cond WHERE count > 0)
          ON CONFLICT (event_id) DO NOTHING
          RETURNING event_id, sequence_position, created_at
        SQL
        cond_params + insert_params
      )

      if result.ntuples.zero? && events.any?
        matching = count_matching(condition.fail_if_events_match, condition.after)
        raise ConditionNotMet, "conflicting event(s)" if matching.positive?

        return []
      end

      events_by_id = events.to_h { |e| [e.id, e] }
      result.map do |row|
        @row_mapper.to_appended_event(events_by_id[row["event_id"]], row)
      end
    end

    def insert_event(event)
      result = @conn.exec_params(@dialect.insert_sql, @dialect.insert_params(event))
      return nil if result.ntuples.zero?

      result[0]
    end

    def notify_appended(position)
      @conn.exec("NOTIFY #{@namespace.channel}, '#{position}'")
    end

    def listen
      @conn.exec("LISTEN #{@namespace.channel}")
    end

    # Called from subscribe's ensure block, where the connection may already
    # be gone (closed socket, failed subscription), so failures are ignored.
    def unlisten
      @conn.exec("UNLISTEN #{@namespace.channel}")
    rescue StandardError
      nil
    end

    def wait_for_append
      @conn.wait_for_notify
    end

    def with_write_transaction
      @conn.exec("BEGIN")
      result = yield
      @conn.exec("COMMIT")
      result
    rescue StandardError
      begin
        @conn.exec("ROLLBACK")
      rescue StandardError
        nil
      end
      raise
    end
  end
end

# Loaded after the class body on purpose: each file below reopens
# `class PostgresStore`, which would raise a superclass mismatch if it ran
# before the `< SqlStore` definition above.
require_relative "postgres_store/array_codec"
require_relative "postgres_store/dialect"
require_relative "postgres_store/lock_keys"
require_relative "postgres_store/schema"
