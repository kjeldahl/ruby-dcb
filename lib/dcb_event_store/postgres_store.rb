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
    # Seconds a subscriber held back by an unfinished transaction waits
    # before it looks again (see #deliver_new): that transaction need not be
    # an append, and then no NOTIFY says it is done.
    HELD_BACK_POLL = 0.1

    # How long #settled waits for each check's advisory locks. Long enough
    # for an append in flight to commit, short enough that the appends
    # queued behind a waiting global-key request hardly notice.
    SETTLE_LOCK_TIMEOUT = "50ms".freeze

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

    # SqlStore#settled, safe against appends in flight: a position is taken
    # at INSERT and becomes visible at COMMIT, so an event matching a
    # check's query below its +through+ may still be uncommitted when the
    # count runs, unless all of them share a tag (issue #55). So each check
    # first takes the advisory locks a condition on its query would take
    # (every append that could write a match holds one of them), waiting at
    # most SETTLE_LOCK_TIMEOUT, and counts only once they are held, in a
    # later statement: a matching append that held one has committed by
    # then, and one that comes after takes a later position. A lock not
    # taken in time fails the check; a later build retries. One transaction
    # for all checks, each in its own savepoint, whose rollback releases its
    # locks before the next check takes its own.
    def settled(checks)
      return [] if checks.empty?

      with_write_transaction do
        @conn.exec("SET LOCAL lock_timeout = '#{settle_lock_timeout}'")
        checks.map { |check| settle(check) }
      end
    end

    private

    def settle_lock_timeout
      SETTLE_LOCK_TIMEOUT
    end

    def settle(check)
      @conn.exec("SAVEPOINT settle")
      settle_locks!(check.query)
      count_between(check.query, check.after, check.through) == check.count
    rescue PG::LockNotAvailable
      false
    ensure
      @conn.exec("ROLLBACK TO SAVEPOINT settle")
    end

    # The keys a condition on +query+ takes (#acquire_locks!), in the same
    # order; the tag keys shared rather than exclusive, so settle checks on
    # one tag do not wait for each other. The global key keeps its mode:
    # exclusive for a query a tag cannot scope, since every append holds it
    # shared.
    def settle_locks!(query)
      locks = LockKeys.for([], AppendCondition.new(fail_if_events_match: query))
      global, tags = advisory_keys(locks)
      @conn.exec("SELECT #{global_lock_function(locks)}(#{global})")
      return if tags.empty?

      @conn.exec_params(<<~SQL, [key_array(tags)])
        SELECT count(pg_advisory_xact_lock_shared(k)) FROM (SELECT unnest($1::bigint[]) AS k ORDER BY 1) AS keys
      SQL
    end

    # The global key and the tag keys +locks+ names, shifted into this
    # namespace's key space: keys of different namespaces never meet, and
    # the default namespace's are unchanged.
    def advisory_keys(locks)
      offset = @namespace.lock_offset
      [offset + LockKeys::APPEND_LOCK_KEY, locks.tags.map { |key| offset + key }]
    end

    def global_lock_function(locks)
      locks.global == :exclusive ? "pg_advisory_xact_lock" : "pg_advisory_xact_lock_shared"
    end

    def key_array(keys)
      "{#{keys.join(',')}}"
    end

    def count_between(query, after, through)
      sql, params = @sql.count_between_sql(query, after, through)
      @conn.exec_params(sql, params)[0]["count"].to_i
    end

    # A position alone cannot be a subscription cursor here: appends on
    # disjoint tags take no common lock, so they can commit out of position
    # order, and a subscriber past a position would never see an event below
    # it that was still in flight (issue #54). The cursor is the
    # [tx_id, sequence_position] of the last event delivered instead, and
    # the subscription walks that order (see #deliver_new). +after+ (a
    # position) resolves to the tx_id of the event at or below it.
    def subscription_cursor(after)
      return nil unless after

      row = @conn.exec_params(<<~SQL, [after]).first
        SELECT tx_id FROM #{@namespace.events_table}
         WHERE sequence_position <= $1 ORDER BY sequence_position DESC LIMIT 1
      SQL
      row && [Integer(row["tx_id"]), after]
    end

    # Delivers the events past +cursor+ in (tx_id, sequence_position) order,
    # up to the first whose transaction is not older than the oldest one
    # still running (pg_snapshot_xmin): every transaction below that is
    # committed or gone, so no event can later appear below the cursor.
    # Positions are delivered in commit order, not ascending; per tag the two
    # agree, since an append takes its tag's lock before its transaction id.
    # Anything matching left past the cursor then is held back, which
    # #wait_for_append turns into a poll.
    def deliver_new(query, cursor, phase, &)
      after = cursor&.last
      events = Enumerator.new do |yielder|
        loop do
          rows = fetch_in_commit_order(query, cursor, BATCH_SIZE)
          rows.each do |row|
            cursor = [Integer(row["tx_id"]), Integer(row["sequence_position"])]
            yielder << @row_mapper.to_sequenced_event(row)
          end
          break if rows.size < BATCH_SIZE
        end
      end
      instrument_subscribe(instrument_read(events, query, ReadOptions.new(after: after)), query, phase, &)
      @held_back = pending?(query, cursor)
      cursor
    end

    def fetch_in_commit_order(query, cursor, limit)
      sql, params = @sql.commit_order_sql(query, cursor)
      @conn.exec_params("#{sql} LIMIT #{limit}", params).to_a
    end

    def pending?(query, cursor)
      sql, params = @sql.pending_sql(query, cursor)
      @conn.exec_params(sql, params).ntuples.positive?
    end

    def fetch_batch(query, **page)
      sql, params = @sql.read_sql(query, **page)
      @conn.exec_params(sql, params).to_a
    end

    def fetch_by_ids(ids)
      sql, params = @sql.by_ids_sql(ids)
      @conn.exec_params(sql, params).to_a
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
      global, tags = advisory_keys(locks)
      @conn.exec("SELECT #{global_lock_function(locks)}(#{global})")
      return if tags.empty?

      @conn.exec_params("SELECT acquire_sorted_advisory_locks($1::bigint[])", [key_array(tags)])
    end

    # PostgreSQL does the conditional append in a single statement: the CTE
    # evaluates the condition and the INSERT ... SELECT only writes rows when
    # the CTE found no conflict, so one round trip covers check and insert.
    # An empty RETURNING means either a conflict or that every event was a
    # duplicate id, which SqlStore#replay tells apart -- so the common case
    # stays one statement, and only an append that wrote nothing looks
    # further.
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

    # The append lock's global key, exclusively: every append holds it at
    # least shared, so none runs alongside an import.
    def lock_for_import!
      @conn.exec("SELECT pg_advisory_xact_lock(#{@namespace.lock_offset + LockKeys::APPEND_LOCK_KEY})")
    end

    def import_event(event)
      result = @conn.exec_params(@dialect.import_sql, @dialect.import_params(event))
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

    # Then drains what else is queued: one read covers every append
    # announced so far, and a NOTIFY per append (queued while a long catch-up
    # ran, say) would otherwise wake the loop once each for nothing.
    def wait_for_append
      @conn.wait_for_notify(@held_back ? HELD_BACK_POLL : nil)
      loop { break unless @conn.wait_for_notify(0) }
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
