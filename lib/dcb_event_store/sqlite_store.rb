require "json"

module DcbEventStore
  # SQLite-backed store: the SqlStore hooks implemented against an
  # SQLite3::Database.
  #
  # Appends run in a BEGIN IMMEDIATE transaction, which takes the database's
  # write lock up front: SQLite has a single writer, so the consistency check
  # and the inserts are serialized against competing appends by construction
  # and no extra locking is needed (where PostgresStore takes per-tag advisory
  # locks to keep disjoint appends parallel).
  #
  # Each appended event also writes one row per tag into the event_tags index
  # table, which the tag containment query joins against in place of
  # PostgreSQL's GIN index.
  #
  # The schema must be installed (or at least Schema.configure! run) on the
  # connection before use.
  class SqliteStore < SqlStore
    def initialize(db, upcaster: nil, subscribe_instrumentation: :event, poll_interval: 0.1)
      super(upcaster: upcaster, subscribe_instrumentation: subscribe_instrumentation)
      @db = db
      # The row mapper reads rows by column name, so hash rows are not
      # optional; a connection that was opened elsewhere may not have them.
      @db.results_as_hash = true
      @poll_interval = poll_interval
      @dialect = Dialect.new
      @sql = SqlBuilder.new(@dialect)
      @row_mapper = RowMapper.new(@dialect, @upcaster)
    end

    private

    def fetch_batch(query, after:, limit:)
      sql, params = @sql.read_sql(query, after: after)
      @db.execute("#{sql} LIMIT ?", params + [limit])
    end

    # Nothing to take: BEGIN IMMEDIATE already made this connection the
    # database's only writer.
    def acquire_locks!(_condition); end

    def count_matching(query, after)
      sql, params = @sql.condition_sql(query, after)
      @db.get_first_value(sql, params).to_i
    end

    def insert_event(event)
      row = @db.get_first_row(@dialect.insert_sql, @dialect.insert_params(event))
      return nil if row.nil?

      insert_tags(event, row["sequence_position"])
      row
    end

    # The index table's primary key is (tag, sequence_position), so a tag
    # repeated on one event must only be written once.
    def insert_tags(event, position)
      event.tags.uniq.each { |tag| @db.execute(@dialect.insert_tag_sql, [tag, position]) }
    end

    # Subscribers poll rather than wait for a notification, so an append has
    # nothing to announce.
    def notify_appended(_position); end

    def listen; end

    def unlisten; end

    def wait_for_append
      sleep @poll_interval
    end

    # Statements with RETURNING must be fully consumed before the COMMIT, or
    # SQLite reports the connection as busy; every read above goes through
    # execute/get_first_row/get_first_value, which step the statement to the
    # end and reset it.
    def with_write_transaction
      @db.execute("BEGIN IMMEDIATE")
      result = yield
      @db.execute("COMMIT")
      result
    rescue StandardError
      begin
        @db.execute("ROLLBACK")
      rescue StandardError
        nil
      end
      raise
    end
  end
end
