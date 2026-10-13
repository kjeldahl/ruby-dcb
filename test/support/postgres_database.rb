require "pg"

# Test-side helper for the PostgreSQL backend: connects to the test database,
# (re)creates the schema, truncates it and builds a PostgresStore.
module PostgresDatabaseHelper
  # The base database the suite runs against. Mutant workers override it with a
  # worker-local database (see #prepare_worker) so concurrent workers neither
  # TRUNCATE nor advisory-lock one another.
  BASE_DATABASE = "dcb_event_store_test".freeze

  @database = ENV.fetch("DCB_TEST_PG_DATABASE", BASE_DATABASE)

  class << self
    # The database the calling process connects to.
    attr_accessor :database

    def connection
      PG.connect(dbname: database)
    end

    # Bind the calling process to a dedicated database: create it if missing and
    # install the schema. Run once per mutant worker before it dispatches any
    # test, so each worker owns its database for the whole run.
    def prepare_worker(database:)
      self.database = database
      create_unless_exists(database)
      conn = connection
      DcbEventStore::PostgresStore::Schema.create!(conn)
      conn.close
      database
    end

    private

    def create_unless_exists(name)
      maintenance = PG.connect(dbname: BASE_DATABASE)
      begin
        found = maintenance.exec("SELECT 1 FROM pg_database WHERE datname = $1", [name]).ntuples.positive?
        maintenance.exec("CREATE DATABASE #{maintenance.quote_ident(name)}") unless found
      ensure
        maintenance.close
      end
    end
  end

  def setup_db
    @conn = PostgresDatabaseHelper.connection
    @conn.exec("SET client_min_messages TO warning")
    DcbEventStore::PostgresStore::Schema.create!(@conn)
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
