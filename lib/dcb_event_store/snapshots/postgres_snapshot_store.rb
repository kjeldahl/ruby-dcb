require "json"

module DcbEventStore
  module Snapshots
    # Snapshots persisted in the projection_snapshots table next to the events
    # (installed by PostgresStore::Schema.create!), so every process sharing
    # the database shares the snapshots and a snapshot is read on the
    # connection that reads the events after it.
    #
    # State travels as JSON (JSONB column). The upsert only moves a snapshot
    # forward: a concurrent builder that folded to a lower position leaves
    # the newer row alone.
    #
    # +namespace:+ picks the snapshot table of that namespace's event log
    # (see Namespace); give it the namespace of the store the snapshots are
    # taken from.
    class PostgresSnapshotStore
      def initialize(conn, namespace: nil)
        @conn = conn
        @table = Namespace.wrap(namespace).snapshots_table
        @upsert_sql = <<~SQL
          INSERT INTO #{@table} (key, position, state, updated_at)
          VALUES ($1, $2, $3::jsonb, now())
          ON CONFLICT (key) DO UPDATE
            SET position = EXCLUDED.position, state = EXCLUDED.state, updated_at = now()
            WHERE #{@table}.position < EXCLUDED.position
        SQL
      end

      def fetch(key)
        fetch_many([key])[key]
      end

      # key => Entry for the keys that have one, in one round trip.
      def fetch_many(keys)
        return {} if keys.empty?

        result = @conn.exec_params(
          "SELECT key, position, state FROM #{@table} WHERE key = ANY($1::text[])",
          [PostgresStore::ArrayCodec.new.encode(keys)]
        )
        result.to_h { |row| [row["key"], entry(row)] }
      end

      def entry(row)
        Snapshot::Entry.new(position: Integer(row["position"]),
                            state: JSON.parse(row["state"], symbolize_names: true))
      end
      private :entry

      def store(key, position:, state:)
        @conn.exec_params(@upsert_sql, [key, position, JSON.generate(state)])
        nil
      end

      def delete(key)
        @conn.exec_params("DELETE FROM #{@table} WHERE key = $1", [key])
        nil
      end

      # Removes the snapshots of projection +name+ in the current epoch, all
      # versions but +keep_version+ (every version when nil). Prefixes are
      # compared with substr rather than LIKE, so a name may contain any
      # character. Returns how many rows were removed.
      def purge(name:, keep_version: nil)
        prefix = Snapshot.key_prefix(name, nil)
        if keep_version
          @conn.exec_params(
            "DELETE FROM #{@table} WHERE substr(key, 1, length($1)) = $1 " \
            "AND substr(key, 1, length($2)) <> $2",
            [prefix, Snapshot.key_prefix(name, keep_version)]
          ).cmd_tuples
        else
          @conn.exec_params("DELETE FROM #{@table} WHERE substr(key, 1, length($1)) = $1", [prefix])
               .cmd_tuples
        end
      end

      # Removes every snapshot not keyed under the current epoch (an epoch
      # must be set). Returns how many rows were removed.
      def purge_other_epochs
        prefix = Snapshot.epoch_prefix or raise ArgumentError, "no epoch is set"
        @conn.exec_params("DELETE FROM #{@table} WHERE substr(key, 1, length($1)) <> $1", [prefix])
             .cmd_tuples
      end

      def clear
        @conn.exec("DELETE FROM #{@table}")
        nil
      end
    end
  end
end
