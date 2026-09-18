require "pg"

# Test-side helper for the PostgreSQL backend: connects to the test database,
# (re)creates the schema, truncates it and builds a PostgresStore.
module PostgresDatabaseHelper
  def self.connection
    PG.connect(dbname: "dcb_event_store_test")
  end

  def setup_db
    @conn = PostgresDatabaseHelper.connection
    @conn.exec("SET client_min_messages TO warning")
    DcbEventStore::Schema.create!(@conn)
    @conn.exec("TRUNCATE events RESTART IDENTITY")
    @store = build_store
  end

  def teardown_db
    @conn&.close
  end

  def build_store(upcaster: nil)
    DcbEventStore::PostgresStore.new(@conn, upcaster: upcaster)
  end
end

# Transitional alias; removed once every backend has its own helper.
DatabaseHelper = PostgresDatabaseHelper
