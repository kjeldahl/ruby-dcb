require_relative "../test_helper"
require_relative "../support/postgres_database"

# Schema.create! on an events table from before tx_id (0.5.0 and earlier)
# adds the column, and the subscription order it drives reads the old rows
# in position order.
class TestSchemaUpgrade < Minitest::Test
  cover "DcbEventStore::PostgresStore::Schema*"

  NAMESPACE = "upgrade".freeze

  def setup
    @conn = PostgresDatabaseHelper.connection
    @conn.exec("SET client_min_messages TO warning")
    DcbEventStore::PostgresStore::Schema.drop!(@conn, namespace: NAMESPACE)
    @conn.exec(<<~SQL)
      CREATE TABLE upgrade_events (
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
      INSERT INTO upgrade_events (type) VALUES ('Old1'), ('Old2');
    SQL
  end

  def teardown
    DcbEventStore::PostgresStore::Schema.drop!(@conn, namespace: NAMESPACE)
    @conn&.close
  end

  def test_create_adds_tx_id_to_a_table_from_before_it
    DcbEventStore::PostgresStore::Schema.create!(@conn, namespace: NAMESPACE)

    nulls = @conn.exec("SELECT count(*) FROM upgrade_events WHERE tx_id IS NULL")[0]["count"]
    assert_equal "0", nulls
    column = @conn.exec(<<~SQL)[0]
      SELECT data_type, is_nullable FROM information_schema.columns
       WHERE table_name = 'upgrade_events' AND column_name = 'tx_id'
    SQL
    assert_equal({ "data_type" => "xid8", "is_nullable" => "NO" }, column)
    assert_equal 1, @conn.exec("SELECT 1 FROM pg_indexes WHERE indexname = 'idx_upgrade_events_tx_id'").ntuples
  end

  def test_an_upgraded_log_is_subscribed_in_position_order
    DcbEventStore::PostgresStore::Schema.create!(@conn, namespace: NAMESPACE)
    DcbEventStore::PostgresStore.new(@conn, namespace: NAMESPACE).append([DcbEventStore::Event.new(type: "New")])

    received = []
    subscriber = Thread.new do
      conn = PostgresDatabaseHelper.connection
      DcbEventStore::PostgresStore.new(conn, namespace: NAMESPACE).subscribe(DcbEventStore::Query.all, after: 1) do |e|
        received << e.type
        break if received.size == 2
      end
    ensure
      conn&.close
    end

    assert subscriber.join(5)
    assert_equal %w[Old2 New], received
  end
end
