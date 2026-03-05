require "pg"

module DatabaseHelper
  def self.connection
    PG.connect(dbname: "dcb_event_store_test")
  end

  def setup_db
    @conn = DatabaseHelper.connection
    DcbEventStore::Schema.create!(@conn)
    @conn.exec("TRUNCATE events RESTART IDENTITY")
    @store = DcbEventStore::Store.new(@conn)
  end

  def teardown_db
    @conn&.close
  end
end
