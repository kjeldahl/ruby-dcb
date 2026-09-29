require_relative "../test_helper"
require_relative "../support/postgres_database"

# Schema.create! on an events table from before tx_id (0.5.0 and earlier)
# adds the column, and the subscription order it drives reads the old rows
# in position order. On a table restored from a cluster whose transaction
# counter ran further, it moves the tx_id offset past the restored rows.
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
    assert_equal({ "data_type" => "bigint", "is_nullable" => "NO" }, column)
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

  def xid
    Integer(@conn.exec("SELECT pg_current_xact_id()")[0]["pg_current_xact_id"])
  end

  def store(conn = @conn)
    DcbEventStore::PostgresStore.new(conn, namespace: NAMESPACE)
  end

  # Subscribes on its own connection until +count+ events arrived; their
  # types, in delivery order.
  def subscribed_types(count, after: nil)
    received = []
    subscriber = Thread.new do
      conn = PostgresDatabaseHelper.connection
      store(conn).subscribe(DcbEventStore::Query.all, after: after) do |e|
        received << e.type
        break if received.size == count
      end
    ensure
      conn&.close
    end
    assert subscriber.join(5), "subscriber got #{received.inspect}, expected #{count} events"
    received
  end

  # Rows as a dump of a cluster further along would restore them: tx_ids
  # this cluster has not handed out yet, in commit order Restored2 before
  # Restored1.
  def restore_rows_from_a_cluster_ahead
    DcbEventStore::PostgresStore::Schema.create!(@conn, namespace: NAMESPACE)
    @conn.exec("TRUNCATE upgrade_events RESTART IDENTITY")
    ahead = xid + 1_000_000
    @conn.exec(<<~SQL)
      INSERT INTO upgrade_events (type, tx_id) VALUES ('Restored1', #{ahead + 5}), ('Restored2', #{ahead})
    SQL
    ahead + 5
  end

  def test_create_moves_new_appends_past_restored_transaction_ids
    newest = restore_rows_from_a_cluster_ahead

    DcbEventStore::PostgresStore::Schema.create!(@conn, namespace: NAMESPACE)
    appended = store.append([DcbEventStore::Event.new(type: "New")]).last

    tx_id = @conn.exec("SELECT tx_id FROM upgrade_events WHERE sequence_position = $1", [appended.sequence_position])
    assert_operator Integer(tx_id[0]["tx_id"]), :>, newest
    assert_equal %w[Restored2 Restored1 New], subscribed_types(3)
    assert_equal %w[New], subscribed_types(1, after: 1)
  end

  # The offset only ever moves when the table is ahead of the cluster: a
  # second install leaves it where the first put it.
  def test_create_leaves_the_offset_alone_otherwise
    restore_rows_from_a_cluster_ahead
    DcbEventStore::PostgresStore::Schema.create!(@conn, namespace: NAMESPACE)
    offset = -> { @conn.exec("SELECT upgrade_events_tx_offset() AS o")[0]["o"] }
    moved = offset.call

    DcbEventStore::PostgresStore::Schema.create!(@conn, namespace: NAMESPACE)

    refute_equal "0", moved
    assert_equal moved, offset.call
  end

  def test_drop_removes_the_offset_function
    DcbEventStore::PostgresStore::Schema.create!(@conn, namespace: NAMESPACE)
    DcbEventStore::PostgresStore::Schema.drop!(@conn, namespace: NAMESPACE)

    assert_nil @conn.exec("SELECT to_regprocedure('upgrade_events_tx_offset()') AS f")[0]["f"]
  end
end
