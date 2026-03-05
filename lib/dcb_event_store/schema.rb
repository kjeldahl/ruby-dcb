module DcbEventStore
  module Schema
    CREATE_SQL = <<~SQL
      CREATE TABLE IF NOT EXISTS events (
        sequence_position BIGSERIAL PRIMARY KEY,
        type              TEXT NOT NULL,
        data              JSONB NOT NULL DEFAULT '{}',
        tags              TEXT[] NOT NULL DEFAULT '{}',
        created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
      );
      CREATE INDEX IF NOT EXISTS idx_events_type ON events (type);
      CREATE INDEX IF NOT EXISTS idx_events_tags ON events USING GIN (tags);
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
