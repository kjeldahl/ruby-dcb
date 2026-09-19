module DcbEventStore
  class PostgresStore
    # DDL for the PostgreSQL backend: the events table with its indexes (GIN
    # on tags), the advisory-lock helper PostgresStore#acquire_locks! calls,
    # the trigger that keeps the table append-only, and the
    # projection_snapshots table Snapshots::PostgresSnapshotStore writes to
    # (mutable by design: no trigger).
    module Schema
      CREATE_SQL = <<~SQL.freeze
        CREATE TABLE IF NOT EXISTS events (
          sequence_position BIGSERIAL PRIMARY KEY,
          event_id          UUID NOT NULL DEFAULT gen_random_uuid(),
          type              TEXT NOT NULL,
          data              JSONB NOT NULL DEFAULT '{}',
          tags              TEXT[] NOT NULL DEFAULT '{}',
          causation_id      UUID,
          correlation_id    UUID,
          schema_version    INTEGER NOT NULL DEFAULT 1,
          created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
        );
        CREATE UNIQUE INDEX IF NOT EXISTS idx_events_event_id ON events (event_id);
        CREATE INDEX IF NOT EXISTS idx_events_type ON events (type);
        CREATE INDEX IF NOT EXISTS idx_events_tags ON events USING GIN (tags);
        CREATE INDEX IF NOT EXISTS idx_events_correlation_id ON events (correlation_id);

        CREATE OR REPLACE FUNCTION acquire_sorted_advisory_locks(lock_keys bigint[])
        RETURNS void AS $$
        DECLARE k bigint;
        BEGIN
          FOREACH k IN ARRAY (SELECT array_agg(x ORDER BY x) FROM unnest(lock_keys) x)
          LOOP
            PERFORM pg_advisory_xact_lock(k);
          END LOOP;
        END;
        $$ LANGUAGE plpgsql;

        CREATE OR REPLACE FUNCTION prevent_event_mutation() RETURNS TRIGGER AS $$
        BEGIN
          RAISE EXCEPTION 'events table is append-only: % not allowed', TG_OP;
        END;
        $$ LANGUAGE plpgsql;

        DROP TRIGGER IF EXISTS enforce_append_only ON events;
        CREATE TRIGGER enforce_append_only
          BEFORE UPDATE OR DELETE ON events
          FOR EACH ROW EXECUTE FUNCTION prevent_event_mutation();

        CREATE TABLE IF NOT EXISTS projection_snapshots (
          key        TEXT PRIMARY KEY,
          position   BIGINT NOT NULL,
          state      JSONB NOT NULL,
          updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
        );
      SQL

      DROP_SQL = <<~SQL.freeze
        DROP TABLE IF EXISTS events CASCADE;
        DROP TABLE IF EXISTS projection_snapshots;
      SQL

      def self.create!(conn)
        conn.exec(CREATE_SQL)
      end

      def self.drop!(conn)
        conn.exec(DROP_SQL)
      end
    end
  end
end
