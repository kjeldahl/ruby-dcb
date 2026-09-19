module DcbEventStore
  class SqliteStore
    # DDL for the SQLite backend, plus the connection pragmas the store
    # expects.
    #
    # Two tables instead of PostgreSQL's one: events carries the tag list as
    # JSON text for the read side, and event_tags(tag, sequence_position) is
    # the lookup index the tag containment query joins against — SQLite has no
    # GIN index, so the index is a table. WITHOUT ROWID keeps it to the primary
    # key alone.
    #
    # Append-only is enforced by BEFORE UPDATE/DELETE triggers on both tables
    # (SQLite triggers are per-statement-per-row, and RAISE(ABORT) surfaces as
    # SQLite3::ConstraintException), matching the PostgreSQL trigger's wording.
    module Schema
      CREATE_SQL = <<~SQL.freeze
        CREATE TABLE IF NOT EXISTS events (
          sequence_position INTEGER PRIMARY KEY AUTOINCREMENT,
          event_id          TEXT NOT NULL UNIQUE,
          type              TEXT NOT NULL,
          data              TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(data)),
          tags              TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(tags)),
          causation_id      TEXT,
          correlation_id    TEXT,
          schema_version    INTEGER NOT NULL DEFAULT 1,
          created_at        INTEGER NOT NULL DEFAULT (CAST(unixepoch('now', 'subsec') * 1000000 AS INTEGER))
        );
        CREATE INDEX IF NOT EXISTS idx_events_type ON events (type);
        CREATE INDEX IF NOT EXISTS idx_events_correlation_id ON events (correlation_id);

        CREATE TABLE IF NOT EXISTS event_tags (
          tag               TEXT NOT NULL,
          sequence_position INTEGER NOT NULL REFERENCES events(sequence_position),
          PRIMARY KEY (tag, sequence_position)
        ) WITHOUT ROWID;

        CREATE TRIGGER IF NOT EXISTS events_no_update BEFORE UPDATE ON events
        BEGIN
          SELECT RAISE(ABORT, 'events table is append-only: UPDATE not allowed');
        END;
        CREATE TRIGGER IF NOT EXISTS events_no_delete BEFORE DELETE ON events
        BEGIN
          SELECT RAISE(ABORT, 'events table is append-only: DELETE not allowed');
        END;
        CREATE TRIGGER IF NOT EXISTS event_tags_no_update BEFORE UPDATE ON event_tags
        BEGIN
          SELECT RAISE(ABORT, 'event_tags table is append-only: UPDATE not allowed');
        END;
        CREATE TRIGGER IF NOT EXISTS event_tags_no_delete BEFORE DELETE ON event_tags
        BEGIN
          SELECT RAISE(ABORT, 'event_tags table is append-only: DELETE not allowed');
        END;
      SQL

      # event_tags first: it references events. DROP TABLE does not fire the
      # append-only triggers, so dropping needs no extra ceremony.
      DROP_SQL = <<~SQL.freeze
        DROP TABLE IF EXISTS event_tags;
        DROP TABLE IF EXISTS events;
      SQL

      # How long a connection waits for the database's write lock before it
      # gives up with SQLite3::BusyException.
      BUSY_TIMEOUT_MS = 5000

      def self.create!(db)
        configure!(db)
        db.execute_batch(CREATE_SQL)
      end

      def self.drop!(db)
        db.execute_batch(DROP_SQL)
      end

      # Connection settings the store relies on: WAL so readers never block
      # the single writer, enforced foreign keys, a busy timeout so a
      # connection waiting for the write lock retries instead of failing
      # immediately, and hash rows because the row mapper reads rows by column
      # name. Per connection, not per database, so every connection opened
      # against the file goes through here.
      #
      # The wait is #busy_handler_timeout=, not SQLite's own busy_timeout:
      # SQLite's handler sleeps inside the C call, which keeps Ruby's global
      # VM lock, so a thread waiting for the lock would stop the thread
      # holding it from ever committing. The gem's handler retries in Ruby and
      # releases the VM lock while it waits.
      def self.configure!(db)
        db.execute("PRAGMA journal_mode=WAL")
        db.execute("PRAGMA foreign_keys=ON")
        db.execute("PRAGMA synchronous=NORMAL")
        db.busy_handler_timeout = BUSY_TIMEOUT_MS
        db.results_as_hash = true
      end
    end
  end
end
