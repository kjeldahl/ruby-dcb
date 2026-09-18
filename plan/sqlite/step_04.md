# Step 4: sqlite3 dependency + SqliteStore::Schema

## Changes
- gemspec: `add_development_dependency "sqlite3", "~> 2.0"`. Move `pg` to dev dep too
  (see overview: both optional). `postgres_store.rb` does `require "pg"` lazily;
  `sqlite_store.rb` does `require "sqlite3"`.
- `lib/dcb_event_store/sqlite_store/schema.rb`:
```sql
CREATE TABLE IF NOT EXISTS events (
  sequence_position INTEGER PRIMARY KEY AUTOINCREMENT,
  event_id          TEXT NOT NULL UNIQUE,
  type              TEXT NOT NULL,
  data              TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(data)),
  tags              TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(tags)),
  causation_id      TEXT,
  correlation_id    TEXT,
  schema_version    INTEGER NOT NULL DEFAULT 1,
  created_at        TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_events_type ON events (type);
CREATE INDEX IF NOT EXISTS idx_events_correlation_id ON events (correlation_id);
CREATE TABLE IF NOT EXISTS event_tags (
  tag               TEXT NOT NULL,
  sequence_position INTEGER NOT NULL REFERENCES events(sequence_position),
  PRIMARY KEY (tag, sequence_position)
) WITHOUT ROWID;
CREATE TRIGGER IF NOT EXISTS enforce_append_only_update BEFORE UPDATE ON events
  BEGIN SELECT RAISE(ABORT, 'events table is append-only: UPDATE not allowed'); END;
CREATE TRIGGER IF NOT EXISTS enforce_append_only_delete BEFORE DELETE ON events
  BEGIN SELECT RAISE(ABORT, 'events table is append-only: DELETE not allowed'); END;
-- same two triggers on event_tags
```
- `Schema.create!(db)`, `Schema.drop!(db)`, `Schema.configure!(db)`:
  `PRAGMA journal_mode=WAL`, `PRAGMA foreign_keys=ON`, `db.busy_timeout = 5000`,
  `db.results_as_hash = true`. `create!` calls `configure!`.
- `Schema.drop!` drops both tables (event_tags first). Tests use fresh tempfile DB per test.
- `test/support/sqlite_database.rb`: `SqliteDatabaseHelper`; `setup_db` uses a tempfile DB
  (`Dir.mktmpdir`), not `:memory:`, so multi-connection tests work.
- `test/sqlite/test_schema.rb`: idempotent create, drop, triggers block UPDATE/DELETE.

## Done when
- `bundle install` works with both gems; schema tests green.
