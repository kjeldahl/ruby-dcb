module DcbEventStore
  class PostgresStore
    # DDL for the PostgreSQL backend (13 or later, for XID8): the events
    # table with its indexes (GIN on tags; tx_id, the appending transaction's
    # id, which PostgresStore#subscribe orders by), the advisory-lock helper
    # PostgresStore#acquire_locks! calls, the trigger that keeps the table
    # append-only, and the projection_snapshots table
    # Snapshots::PostgresSnapshotStore writes to (mutable by design: no
    # trigger).
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

      # Two-integer advisory-lock key (a key space apart from the bigint keys
      # appends take) that serializes installs, see .create_sql.
      INSTALL_LOCK_KEY = "1684108385, 1".freeze

      def self.create!(conn, namespace: nil)
        conn.exec(create_sql(namespace))
      end

      # Drops the namespace's tables. The shared functions stay: another
      # namespace may still be using them.
      def self.drop!(conn, namespace: nil)
        conn.exec(drop_sql(namespace))
      end

      # The full DDL for +namespace+ (nil = the default), idempotent. It
      # opens with a transaction-scoped advisory lock, held until the script's
      # transaction ends, so installs racing at boot queue up instead of
      # failing on the shared functions ("tuple concurrently updated") or on
      # the tables. The ALTER upgrades an events table from before tx_id:
      # its rows all take the installing transaction's id, so they keep
      # their position order. See .tx_offset_sql for the rest of tx_id.
      def self.create_sql(namespace = nil)
        namespace = Namespace.wrap(namespace)
        events = namespace.events_table
        tx_id = "BIGINT NOT NULL DEFAULT (pg_current_xact_id()::text::bigint + #{namespace.tx_offset_function}())"
        <<~SQL
          SELECT pg_advisory_xact_lock(#{INSTALL_LOCK_KEY});

          #{tx_offset_function_sql(namespace)}
          CREATE TABLE IF NOT EXISTS #{events} (
            sequence_position BIGSERIAL PRIMARY KEY,
            event_id          UUID NOT NULL DEFAULT gen_random_uuid(),
            type              TEXT NOT NULL,
            data              JSONB NOT NULL DEFAULT '{}',
            tags              TEXT[] NOT NULL DEFAULT '{}',
            causation_id      UUID,
            correlation_id    UUID,
            schema_version    INTEGER NOT NULL DEFAULT 1,
            created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
            tx_id             #{tx_id}
          );
          ALTER TABLE #{events} ADD COLUMN IF NOT EXISTS tx_id #{tx_id};
          CREATE UNIQUE INDEX IF NOT EXISTS idx_#{events}_event_id ON #{events} (event_id);
          CREATE INDEX IF NOT EXISTS idx_#{events}_type ON #{events} (type);
          CREATE INDEX IF NOT EXISTS idx_#{events}_tags ON #{events} USING GIN (tags);
          CREATE INDEX IF NOT EXISTS idx_#{events}_correlation_id ON #{events} (correlation_id);
          CREATE INDEX IF NOT EXISTS idx_#{events}_tx_id ON #{events} (tx_id, sequence_position);
          #{rebase_tx_offset_sql(namespace)}
          #{FUNCTIONS_SQL}
          DROP TRIGGER IF EXISTS enforce_append_only ON #{events};
          CREATE TRIGGER enforce_append_only
            BEFORE UPDATE OR DELETE ON #{events}
            FOR EACH ROW EXECUTE FUNCTION prevent_event_mutation();

          CREATE TABLE IF NOT EXISTS #{namespace.snapshots_table} (
            key        TEXT PRIMARY KEY,
            position   BIGINT NOT NULL,
            state      JSONB NOT NULL,
            updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
          );
        SQL
      end

      # tx_id is the appending transaction's id plus a per-namespace offset,
      # held by a function so the column default and the subscription's
      # watermark (PostgresStore::Dialect#settled_clause) read the same one.
      # Created at 0; an existing function keeps its value.
      def self.tx_offset_function_sql(namespace)
        function = namespace.tx_offset_function
        <<~SQL
          DO $$ BEGIN
            IF to_regprocedure('#{function}()') IS NULL THEN
              CREATE FUNCTION #{function}() RETURNS bigint LANGUAGE sql STABLE AS 'SELECT 0::bigint';
            END IF;
          END $$;
        SQL
      end

      # Transaction ids are the cluster's own: rows restored from a dump of a
      # cluster whose counter ran further than this one's carry ids this one
      # has not reached yet. They would never count as settled, and new
      # appends would sort before them. So when the table holds a tx_id past
      # any this cluster could have written, the offset moves up to put new
      # appends after it. No row is rewritten, so their order and positions
      # stay as they were. The table lock keeps appends out while it runs.
      def self.rebase_tx_offset_sql(namespace)
        events = namespace.events_table
        function = namespace.tx_offset_function
        <<~SQL
          DO $$
          DECLARE
            newest bigint;
            xid bigint := pg_current_xact_id()::text::bigint;
          BEGIN
            LOCK TABLE #{events} IN SHARE ROW EXCLUSIVE MODE;
            SELECT max(tx_id) INTO newest FROM #{events};
            IF newest > xid + #{function}() THEN
              EXECUTE format('CREATE OR REPLACE FUNCTION #{function}() RETURNS bigint LANGUAGE sql STABLE AS %L',
                             format('SELECT %s::bigint', newest + 1 - xid));
            END IF;
          END $$;
        SQL
      end

      def self.drop_sql(namespace = nil)
        namespace = Namespace.wrap(namespace)
        <<~SQL
          DROP TABLE IF EXISTS #{namespace.events_table} CASCADE;
          DROP TABLE IF EXISTS #{namespace.snapshots_table};
          DROP FUNCTION IF EXISTS #{namespace.tx_offset_function}();
        SQL
      end

      # The default namespace's DDL as constants, from before namespaces.
      CREATE_SQL = create_sql.freeze
      DROP_SQL = drop_sql.freeze
      deprecate_constant :CREATE_SQL, :DROP_SQL
    end
  end
end
