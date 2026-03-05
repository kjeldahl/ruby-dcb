# Step 3: Schema Helper

## Goal
Provide a programmatic way to create and drop the events table in PostgreSQL.

## Files to Create
- `lib/dcb_event_store/schema.rb`
  - `DcbEventStore::Schema.create!(conn)` -- executes CREATE TABLE IF NOT EXISTS + indexes
  - `DcbEventStore::Schema.drop!(conn)` -- executes DROP TABLE IF EXISTS
  - `conn` is a `PG::Connection` instance

## SQL
```sql
CREATE TABLE IF NOT EXISTS events (
  sequence_position BIGSERIAL PRIMARY KEY,
  type              TEXT NOT NULL,
  data              JSONB NOT NULL DEFAULT '{}',
  tags              TEXT[] NOT NULL DEFAULT '{}',
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_events_type ON events (type);
CREATE INDEX IF NOT EXISTS idx_events_tags ON events USING GIN (tags);
```

## Done When
- Given a PG connection to a test database:
  - `Schema.create!(conn)` creates the table (idempotent, can run twice)
  - `Schema.drop!(conn)` drops it
  - Table has correct columns verified via `\d events` or information_schema query
