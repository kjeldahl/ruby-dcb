require "sqlite3"
require "tmpdir"
require "fileutils"

# Test-side helper for the SQLite backend: creates a throwaway database file,
# installs the schema and builds a SqliteStore.
#
# A file database, not ":memory:", because an in-memory database belongs to
# the connection that opened it and could not be shared by the concurrency and
# subscribe tests.
module SqliteDatabaseHelper
  # Opens an additional, fully configured connection on an existing database
  # file, for tests that need a second writer or reader.
  def self.connection(path)
    db = SQLite3::Database.new(path)
    DcbEventStore::SqliteStore::Schema.configure!(db)
    db
  end

  def setup_db
    @dir = Dir.mktmpdir("dcb_event_store")
    @db_path = File.join(@dir, "events.sqlite3")
    @db = SQLite3::Database.new(@db_path)
    DcbEventStore::SqliteStore::Schema.create!(@db)
    @store = build_store
  end

  def teardown_db
    @db&.close
    FileUtils.remove_entry(@dir) if @dir
  end

  def build_store(upcaster: nil)
    DcbEventStore::SqliteStore.new(@db, upcaster: upcaster)
  end
end
