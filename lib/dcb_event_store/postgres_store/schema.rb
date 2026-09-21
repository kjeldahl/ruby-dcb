module DcbEventStore
  class PostgresStore
    # DDL for the PostgreSQL backend: the events table with its indexes (GIN
    # on tags), the advisory-lock helper PostgresStore#acquire_locks! calls,
    # the trigger that keeps the table append-only, and the
    # projection_snapshots table Snapshots::PostgresSnapshotStore writes to
    # (mutable by design: no trigger).
    #
    # Installed once per namespace (see Namespace): each namespace gets its
    # own tables, indexes and trigger under its prefix, while the two
    # functions are shared and CREATE OR REPLACEd on every install.
    module Schema
      # Shared by every namespace: the lock helper and the trigger function,
      # which names the table it fired on.
      FUNCTIONS_SQL = <<~SQL.freeze
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
          RAISE EXCEPTION '% table is append-only: % not allowed', TG_TABLE_NAME, TG_OP;
        END;
        $$ LANGUAGE plpgsql;
      SQL

      def self.create!(conn, namespace: nil)
        conn.exec(create_sql(namespace))
      end

      # Drops the namespace's tables. The shared functions stay: another
      # namespace may still be using them.
      def self.drop!(conn, namespace: nil)
        conn.exec(drop_sql(namespace))
      end

      # The full DDL for +namespace+ (nil = the default), idempotent.
      def self.create_sql(namespace = nil)
        namespace = Namespace.wrap(namespace)
        events = namespace.events_table
        snapshots = namespace.snapshots_table
        <<~SQL
          CREATE TABLE IF NOT EXISTS #{events} (
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
          CREATE UNIQUE INDEX IF NOT EXISTS idx_#{events}_event_id ON #{events} (event_id);
          CREATE INDEX IF NOT EXISTS idx_#{events}_type ON #{events} (type);
          CREATE INDEX IF NOT EXISTS idx_#{events}_tags ON #{events} USING GIN (tags);
          CREATE INDEX IF NOT EXISTS idx_#{events}_correlation_id ON #{events} (correlation_id);

          #{FUNCTIONS_SQL}
          DROP TRIGGER IF EXISTS enforce_append_only ON #{events};
          CREATE TRIGGER enforce_append_only
            BEFORE UPDATE OR DELETE ON #{events}
            FOR EACH ROW EXECUTE FUNCTION prevent_event_mutation();

          CREATE TABLE IF NOT EXISTS #{snapshots} (
            key        TEXT PRIMARY KEY,
            position   BIGINT NOT NULL,
            state      JSONB NOT NULL,
            updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
          );
        SQL
      end

      def self.drop_sql(namespace = nil)
        namespace = Namespace.wrap(namespace)
        <<~SQL
          DROP TABLE IF EXISTS #{namespace.events_table} CASCADE;
          DROP TABLE IF EXISTS #{namespace.snapshots_table};
        SQL
      end
    end
  end
end
