module DcbEventStore
  module Schema
    CREATE_SQL = <<~SQL
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

      CREATE OR REPLACE FUNCTION prevent_event_mutation() RETURNS TRIGGER AS $$
      BEGIN
        RAISE EXCEPTION 'events table is append-only: % not allowed', TG_OP;
      END;
      $$ LANGUAGE plpgsql;

      DROP TRIGGER IF EXISTS enforce_append_only ON events;
      CREATE TRIGGER enforce_append_only
        BEFORE UPDATE OR DELETE ON events
        FOR EACH ROW EXECUTE FUNCTION prevent_event_mutation();
    SQL

    DROP_SQL = "DROP TABLE IF EXISTS events CASCADE;"

    def self.create!(conn)
      conn.exec(CREATE_SQL)
    end

    def self.drop!(conn)
      conn.exec(DROP_SQL)
    end
  end
end
