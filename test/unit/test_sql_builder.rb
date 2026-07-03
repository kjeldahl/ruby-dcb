require_relative "../test_helper"
require "pg"

class TestSqlBuilder < Minitest::Test
  cover "DcbEventStore::Store::SqlBuilder*"

  def setup
    @builder = DcbEventStore::Store::SqlBuilder.new(DcbEventStore::PgArrayCodec.new)
  end

  def query(items)
    DcbEventStore::Query.new(items)
  end

  def item(event_types: [], tags: [])
    DcbEventStore::QueryItem.new(event_types: event_types, tags: tags)
  end

  # --- read_sql ---

  def test_read_sql_match_all_no_after
    sql, params = @builder.read_sql(DcbEventStore::Query.all, after: nil)
    assert_equal "SELECT * FROM events ORDER BY sequence_position ASC", sql
    assert_equal [], params
  end

  def test_read_sql_match_all_with_after
    sql, params = @builder.read_sql(DcbEventStore::Query.all, after: 7)
    assert_equal "SELECT * FROM events WHERE sequence_position > $1 ORDER BY sequence_position ASC", sql
    assert_equal [7], params
  end

  def test_read_sql_event_types_only
    sql, params = @builder.read_sql(query([item(event_types: %w[A B])]), after: nil)
    assert_equal "SELECT * FROM events WHERE (type = ANY($1::text[])) ORDER BY sequence_position ASC", sql
    assert_equal ["{A,B}"], params
  end

  def test_read_sql_tags_only
    sql, params = @builder.read_sql(query([item(tags: %w[t1 t2])]), after: nil)
    assert_equal "SELECT * FROM events WHERE (tags @> $1::text[]) ORDER BY sequence_position ASC", sql
    assert_equal ["{t1,t2}"], params
  end

  def test_read_sql_types_and_tags_combined_with_and
    sql, params = @builder.read_sql(query([item(event_types: ["A"], tags: ["t1"])]), after: nil)
    expected = "SELECT * FROM events WHERE (type = ANY($1::text[]) AND tags @> $2::text[]) " \
               "ORDER BY sequence_position ASC"
    assert_equal expected, sql
    assert_equal ["{A}", "{t1}"], params
  end

  def test_read_sql_drops_items_without_types_or_tags
    # An item constraining neither types nor tags contributes no clause and is
    # filtered out, leaving only the meaningful item.
    sql, params = @builder.read_sql(query([item, item(event_types: ["A"])]), after: nil)
    assert_equal "SELECT * FROM events WHERE (type = ANY($1::text[])) ORDER BY sequence_position ASC", sql
    assert_equal ["{A}"], params
  end

  def test_read_sql_multiple_items_joined_with_or
    sql, params = @builder.read_sql(query([item(event_types: ["A"]), item(tags: ["t1"])]), after: nil)
    expected = "SELECT * FROM events WHERE (type = ANY($1::text[])) OR (tags @> $2::text[]) " \
               "ORDER BY sequence_position ASC"
    assert_equal expected, sql
    assert_equal ["{A}", "{t1}"], params
  end

  def test_read_sql_query_with_after_wraps_clause
    sql, params = @builder.read_sql(query([item(event_types: ["A"])]), after: 3)
    expected = "SELECT * FROM events WHERE ((type = ANY($1::text[]))) AND sequence_position > $2 " \
               "ORDER BY sequence_position ASC"
    assert_equal expected, sql
    assert_equal ["{A}", 3], params
  end

  # --- read_sql ordering / paging (browser) ---

  def test_read_sql_order_desc
    sql, params = @builder.read_sql(DcbEventStore::Query.all, after: nil, order: :desc)
    assert_equal "SELECT * FROM events ORDER BY sequence_position DESC", sql
    assert_equal [], params
  end

  def test_read_sql_limit
    sql, params = @builder.read_sql(DcbEventStore::Query.all, after: nil, limit: 25)
    assert_equal "SELECT * FROM events ORDER BY sequence_position ASC LIMIT 25", sql
    assert_equal [], params
  end

  def test_read_sql_offset
    sql, params = @builder.read_sql(DcbEventStore::Query.all, after: nil, offset: 50)
    assert_equal "SELECT * FROM events ORDER BY sequence_position ASC OFFSET 50", sql
    assert_equal [], params
  end

  def test_read_sql_desc_limit_offset_combined
    sql, params = @builder.read_sql(DcbEventStore::Query.all, after: nil, order: :desc, limit: 25, offset: 50)
    assert_equal "SELECT * FROM events ORDER BY sequence_position DESC LIMIT 25 OFFSET 50", sql
    assert_equal [], params
  end

  def test_read_sql_desc_limit_with_filter
    sql, params = @builder.read_sql(query([item(event_types: ["A"])]), after: nil, order: :desc, limit: 10)
    expected = "SELECT * FROM events WHERE (type = ANY($1::text[])) " \
               "ORDER BY sequence_position DESC LIMIT 10"
    assert_equal expected, sql
    assert_equal ["{A}"], params
  end

  def test_read_sql_rejects_unknown_order
    error = assert_raises(ArgumentError) do
      @builder.read_sql(DcbEventStore::Query.all, after: nil, order: :sideways)
    end
    assert_equal "order must be :asc or :desc", error.message
  end

  def test_read_sql_coerces_numeric_string_limit_and_offset
    sql, = @builder.read_sql(DcbEventStore::Query.all, after: nil, limit: "25", offset: "50")
    assert_equal "SELECT * FROM events ORDER BY sequence_position ASC LIMIT 25 OFFSET 50", sql
  end

  def test_read_sql_rejects_non_integer_limit
    assert_raises(ArgumentError) do
      @builder.read_sql(DcbEventStore::Query.all, after: nil, limit: "25; DROP TABLE events")
    end
  end

  def test_read_sql_rejects_non_integer_offset
    assert_raises(ArgumentError) do
      @builder.read_sql(DcbEventStore::Query.all, after: nil, offset: "0 OR 1=1")
    end
  end

  # --- count_sql ---

  def test_count_sql_match_all
    sql, params = @builder.count_sql(DcbEventStore::Query.all)
    assert_equal "SELECT COUNT(*) FROM events", sql
    assert_equal [], params
  end

  def test_count_sql_with_where
    sql, params = @builder.count_sql(query([item(event_types: ["A"])]))
    assert_equal "SELECT COUNT(*) FROM events WHERE (type = ANY($1::text[]))", sql
    assert_equal ["{A}"], params
  end

  def test_count_sql_with_after
    sql, params = @builder.count_sql(query([item(event_types: ["A"])]), after: 5)
    assert_equal "SELECT COUNT(*) FROM events WHERE ((type = ANY($1::text[]))) AND sequence_position > $2", sql
    assert_equal ["{A}", 5], params
  end

  def test_count_sql_match_all_with_after
    sql, params = @builder.count_sql(DcbEventStore::Query.all, after: 9)
    assert_equal "SELECT COUNT(*) FROM events WHERE sequence_position > $1", sql
    assert_equal [9], params
  end

  # --- values_clause ---

  def test_values_clause_single_event_no_offset
    event = DcbEventStore::Event.new(type: "A", data: { n: 1 }, tags: ["t1"],
                                     id: "id-1", causation_id: "c-1", correlation_id: "r-1")
    rows, params = @builder.values_clause([event], 0)

    assert_equal [
      "($1::uuid, $2::text, $3::jsonb, $4::text[], $5::uuid, $6::uuid, $7::integer)"
    ], rows
    assert_equal ["id-1", "A", '{"n":1}', "{t1}", "c-1", "r-1", 1], params
  end

  def test_values_clause_respects_param_offset
    event = DcbEventStore::Event.new(type: "A", id: "id-1")
    rows, = @builder.values_clause([event], 2)
    assert_equal [
      "($3::uuid, $4::text, $5::jsonb, $6::text[], $7::uuid, $8::uuid, $9::integer)"
    ], rows
  end

  def test_values_clause_multiple_events_increment_placeholders
    e1 = DcbEventStore::Event.new(type: "A", id: "id-1")
    e2 = DcbEventStore::Event.new(type: "B", id: "id-2")
    rows, params = @builder.values_clause([e1, e2], 0)

    assert_equal [
      "($1::uuid, $2::text, $3::jsonb, $4::text[], $5::uuid, $6::uuid, $7::integer)",
      "($8::uuid, $9::text, $10::jsonb, $11::text[], $12::uuid, $13::uuid, $14::integer)"
    ], rows
    assert_equal 14, params.size
    assert_equal "id-1", params[0]
    assert_equal "id-2", params[7]
  end
end
