require "json"

module DcbEventStore
  module Snapshots
    # The SQLite twin of PostgresSnapshotStore: same table, same forward-only
    # upsert, state as JSON text.
    class SqliteSnapshotStore
      module Schema
        CREATE_SQL = <<~SQL.freeze
          CREATE TABLE IF NOT EXISTS projection_snapshots (
            key        TEXT PRIMARY KEY,
            position   INTEGER NOT NULL,
            state      TEXT NOT NULL CHECK (json_valid(state)),
            updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
          );
        SQL

        DROP_SQL = "DROP TABLE IF EXISTS projection_snapshots;".freeze

        def self.create!(db) = db.execute_batch(CREATE_SQL)
        def self.drop!(db) = db.execute_batch(DROP_SQL)
      end

      UPSERT_SQL = <<~SQL.freeze
        INSERT INTO projection_snapshots (key, position, state)
        VALUES (?, ?, ?)
        ON CONFLICT (key) DO UPDATE
          SET position = excluded.position, state = excluded.state,
              updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
          WHERE projection_snapshots.position < excluded.position
      SQL

      def initialize(db)
        @db = db
      end

      def fetch(key)
        fetch_many([key])[key]
      end

      # key => Entry for the keys that have one, in one statement.
      def fetch_many(keys)
        return {} if keys.empty?

        rows = @db.execute(
          "SELECT key, position, state FROM projection_snapshots WHERE key IN (SELECT value FROM json_each(?))",
          [JSON.generate(keys)]
        )
        rows.to_h do |row|
          key, position, state = row.is_a?(Hash) ? row.values_at("key", "position", "state") : row
          [key, Snapshot::Entry.new(position: Integer(position), state: JSON.parse(state, symbolize_names: true))]
        end
      end

      def store(key, position:, state:)
        @db.execute(UPSERT_SQL, [key, position, JSON.generate(state)])
        nil
      end

      def delete(key)
        @db.execute("DELETE FROM projection_snapshots WHERE key = ?", [key])
        nil
      end

      def clear
        @db.execute("DELETE FROM projection_snapshots")
        nil
      end
    end
  end
end
