require "json"

require_relative "sql_store"

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
  # Subscribers poll instead of waiting for a notification: SQLite has no
  # LISTEN/NOTIFY, so #wait_for_append sleeps poll_interval and checks two
  # cheap change counters before the subscribe loop reads again.
  #
  # The schema must be installed (or at least Schema.configure! run) on the
  # connection before use.
  class SqliteStore < SqlStore
    attr_reader :poll_interval

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

    def max_position
      @db.get_first_value("SELECT max(sequence_position) FROM events")
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

    # Records the change counters #wait_for_append compares against, so the
    # first poll only reads when something was written after the catch-up.
    def listen
      @data_version = data_version
      @total_changes = @db.total_changes
    end

    def unlisten; end

    # Sleeps a poll interval at a time until one of two signals moved, and
    # neither alone is enough:
    #
    # - PRAGMA data_version changes when *another* connection commits to the
    #   database, and never for this connection's own commits. It covers the
    #   normal setup, where the subscriber holds its own connection.
    # - SQLite3::Database#total_changes counts the rows this connection wrote,
    #   and sees nothing of other connections' writes. It covers a store that
    #   appends and subscribes over one connection.
    #
    # Both readings are refreshed on every return, so the next wait compares
    # against what this wake-up saw. Only the wake-up is approximate: what is
    # actually delivered comes from the subscribe loop's read, so a wake-up
    # for an unrelated write just reads nothing.
    def wait_for_append
      loop do
        sleep @poll_interval
        version = data_version
        changes = @db.total_changes
        next if version == @data_version && changes == @total_changes

        @data_version = version
        @total_changes = changes
        break
      end
    end

    def data_version
      @db.get_first_value("PRAGMA data_version")
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

# Loaded after the class body on purpose: each file below reopens
# `class SqliteStore`, which would raise a superclass mismatch if it ran
# before the `< SqlStore` definition above.
require_relative "sqlite_store/dialect"
require_relative "sqlite_store/schema"
