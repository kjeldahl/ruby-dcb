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
    #
    # projection_snapshots, written by Snapshots::SqliteSnapshotStore, is the
    # one mutable table: no trigger.
    #
    # Installed once per namespace (see Namespace): each namespace gets its
    # own three tables and four triggers under its prefix. Trigger names are
    # database-wide in SQLite, so they carry the table name.
    module Schema
      # How long a connection waits for the database's write lock before it
      # gives up with SQLite3::BusyException.
      BUSY_TIMEOUT_MS = 5000

      def self.create!(db, namespace: nil)
        configure!(db)
        db.execute_batch(create_sql(namespace))
      end

      def self.drop!(db, namespace: nil)
        db.execute_batch(drop_sql(namespace))
      end

      # The full DDL for +namespace+ (nil = the default), idempotent.
      def self.create_sql(namespace = nil)
        namespace = Namespace.wrap(namespace)
        events = namespace.events_table
        event_tags = namespace.event_tags_table
        <<~SQL
          CREATE TABLE IF NOT EXISTS #{events} (
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
          CREATE INDEX IF NOT EXISTS idx_#{events}_type ON #{events} (type);
          CREATE INDEX IF NOT EXISTS idx_#{events}_correlation_id ON #{events} (correlation_id);

          CREATE TABLE IF NOT EXISTS #{event_tags} (
            tag               TEXT NOT NULL,
            sequence_position INTEGER NOT NULL REFERENCES #{events}(sequence_position),
            PRIMARY KEY (tag, sequence_position)
          ) WITHOUT ROWID;

          #{append_only_triggers(events)}
          #{append_only_triggers(event_tags)}
          CREATE TABLE IF NOT EXISTS #{namespace.snapshots_table} (
            key        TEXT PRIMARY KEY,
            position   INTEGER NOT NULL,
            state      TEXT NOT NULL CHECK (json_valid(state)),
            updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
          );
        SQL
      end

      # event_tags first: it references events. DROP TABLE does not fire the
      # append-only triggers, so dropping needs no extra ceremony.
      def self.drop_sql(namespace = nil)
        namespace = Namespace.wrap(namespace)
        <<~SQL
          DROP TABLE IF EXISTS #{namespace.event_tags_table};
          DROP TABLE IF EXISTS #{namespace.events_table};
          DROP TABLE IF EXISTS #{namespace.snapshots_table};
        SQL
      end

      def self.append_only_triggers(table)
        <<~SQL
          CREATE TRIGGER IF NOT EXISTS #{table}_no_update BEFORE UPDATE ON #{table}
          BEGIN
            SELECT RAISE(ABORT, '#{table} table is append-only: UPDATE not allowed');
          END;
          CREATE TRIGGER IF NOT EXISTS #{table}_no_delete BEFORE DELETE ON #{table}
          BEGIN
            SELECT RAISE(ABORT, '#{table} table is append-only: DELETE not allowed');
          END;
        SQL
      end
      private_class_method :append_only_triggers

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
