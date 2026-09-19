require_relative "../test_helper"
require "pg"

# The PostgreSQL dialect is what makes SqlBuilder's statements PostgreSQL:
# every fragment is asserted verbatim, together with the bind parameters the
# clause builders push onto the array they are handed.
class TestPostgresDialect < Minitest::Test
  cover "DcbEventStore::PostgresStore::Dialect*"

  def setup
    @dialect = DcbEventStore::PostgresStore::Dialect.new
  end

  def event(**attrs)
    DcbEventStore::Event.new(type: "A", data: { n: 1 }, tags: ["t1"],
                             id: "id-1", causation_id: "c-1", correlation_id: "r-1", **attrs)
  end

  # --- placeholder ---

  def test_placeholder_is_numbered_from_one
    assert_equal "$1", @dialect.placeholder(1)
    assert_equal "$7", @dialect.placeholder(7)
    assert_equal "$10", @dialect.placeholder(10)
  end

  # --- type_in ---

  def test_type_in_encodes_the_list_and_refers_to_it
    params = []
    assert_equal "type = ANY($1::text[])", @dialect.type_in(params, %w[A B])
    assert_equal ["{A,B}"], params
  end

  def test_type_in_numbers_off_the_params_already_collected
    params = %w[x y]
    assert_equal "type = ANY($3::text[])", @dialect.type_in(params, ["A"])
    assert_equal ["x", "y", "{A}"], params
  end

  # --- tags_contain ---

  def test_tags_contain_encodes_the_list_and_refers_to_it
    params = []
    assert_equal "tags @> $1::text[]", @dialect.tags_contain(params, %w[t1 t2])
    assert_equal ["{t1,t2}"], params
  end

  def test_tags_contain_numbers_off_the_params_already_collected
    params = ["x"]
    assert_equal "tags @> $2::text[]", @dialect.tags_contain(params, ["t1"])
    assert_equal ["x", "{t1}"], params
  end

  # --- after_clause ---

  def test_after_clause_binds_the_position
    params = []
    assert_equal "sequence_position > $1", @dialect.after_clause(params, 7)
    assert_equal [7], params
  end

  def test_after_clause_numbers_off_the_params_already_collected
    params = %w[x y]
    assert_equal "sequence_position > $3", @dialect.after_clause(params, 4)
    assert_equal ["x", "y", 4], params
  end

  # --- insert_row ---

  def test_insert_row_casts_every_column_and_appends_the_params
    params = []
    row = @dialect.insert_row(params, event)

    assert_equal "($1::uuid, $2::text, $3::jsonb, $4::text[], $5::uuid, $6::uuid, $7::integer)", row
    assert_equal ["id-1", "A", '{"n":1}', "{t1}", "c-1", "r-1", 1], params
  end

  def test_insert_row_continues_the_numbering_after_existing_params
    params = %w[x y]
    row = @dialect.insert_row(params, event)

    assert_equal "($3::uuid, $4::text, $5::jsonb, $6::text[], $7::uuid, $8::uuid, $9::integer)", row
    assert_equal ["x", "y", "id-1", "A", '{"n":1}', "{t1}", "c-1", "r-1", 1], params
  end

  def test_insert_row_of_several_events_keeps_counting
    params = []
    first = @dialect.insert_row(params, event)
    second = @dialect.insert_row(params, event(id: "id-2"))

    assert_equal "($1::uuid, $2::text, $3::jsonb, $4::text[], $5::uuid, $6::uuid, $7::integer)", first
    assert_equal "($8::uuid, $9::text, $10::jsonb, $11::text[], $12::uuid, $13::uuid, $14::integer)", second
    assert_equal 14, params.size
    assert_equal "id-2", params[7]
  end

  # --- insert_sql / insert_params ---

  def test_insert_sql
    expected = <<~SQL
      INSERT INTO events (event_id, type, data, tags, causation_id, correlation_id, schema_version)
      VALUES ($1, $2, $3::jsonb, $4::text[], $5, $6, $7)
      ON CONFLICT (event_id) DO NOTHING
      RETURNING sequence_position, created_at
    SQL
    assert_equal expected, @dialect.insert_sql
  end

  def test_insert_params_are_in_column_order
    assert_equal ["id-1", "A", '{"n":1}', "{t1}", "c-1", "r-1", 1], @dialect.insert_params(event)
  end

  def test_insert_params_of_a_bare_event
    bare = DcbEventStore::Event.new(type: "B", id: "id-2")
    assert_equal ["id-2", "B", "{}", "{}", nil, nil, 1], @dialect.insert_params(bare)
  end

  # --- encode_list / decode_list ---

  def test_encode_list_writes_a_pg_array_literal
    assert_equal "{}", @dialect.encode_list([])
    assert_equal "{a,b}", @dialect.encode_list(%w[a b])
    assert_equal '{"a,b"}', @dialect.encode_list(["a,b"])
  end

  def test_decode_list_reads_a_pg_array_literal
    assert_equal [], @dialect.decode_list(nil)
    assert_equal [], @dialect.decode_list("{}")
    assert_equal %w[a b], @dialect.decode_list("{a,b}")
    assert_equal ["a,b"], @dialect.decode_list('{"a,b"}')
  end

  # --- decode_timestamp ---

  def test_decode_timestamp_passes_through_a_time_the_driver_built
    # The store's type map decodes TIMESTAMPTZ in the driver, so the common
    # case is a Time that must not be rebuilt.
    time = Time.utc(2026, 6, 13, 22, 0, 0)

    assert_same time, @dialect.decode_timestamp(time)
  end

  def test_decode_timestamp_passes_through_a_subclass_of_time
    # Type maps are the caller's to replace, and a decoder of theirs may
    # build something that is a Time without being exactly one.
    subclass = Class.new(Time).now

    assert_same subclass, @dialect.decode_timestamp(subclass)
  end

  def test_decode_timestamp_parses_text
    # A connection whose type map was replaced, or a column typed TIMESTAMP
    # rather than TIMESTAMPTZ, still hands back text.
    decoded = @dialect.decode_timestamp("2026-06-13 22:00:00.123456+00")

    assert_equal Time.parse("2026-06-13 22:00:00.123456+00"), decoded
    assert_equal 123_456, decoded.usec
  end
end
