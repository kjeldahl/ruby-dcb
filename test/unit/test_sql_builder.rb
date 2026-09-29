require_relative "../test_helper"
require "pg"

# Built with the PostgreSQL dialect, so the expected SQL below is the SQL the
# PG store has always sent: these assertions are what keeps the dialect
# extraction byte-for-byte faithful.
class TestSqlBuilder < Minitest::Test
  cover "DcbEventStore::SqlStore::SqlBuilder*"

  def setup
    @builder = DcbEventStore::SqlStore::SqlBuilder.new(DcbEventStore::PostgresStore::Dialect.new)
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

  # --- condition_sql ---

  def test_condition_sql_match_all
    sql, params = @builder.condition_sql(DcbEventStore::Query.all, nil)
    assert_equal "SELECT COUNT(*) FROM events", sql
    assert_equal [], params
  end

  def test_condition_sql_with_where
    sql, params = @builder.condition_sql(query([item(event_types: ["A"])]), nil)
    assert_equal "SELECT COUNT(*) FROM events WHERE (type = ANY($1::text[]))", sql
    assert_equal ["{A}"], params
  end

  def test_condition_sql_with_after
    sql, params = @builder.condition_sql(query([item(event_types: ["A"])]), 5)
    assert_equal "SELECT COUNT(*) FROM events WHERE ((type = ANY($1::text[]))) AND sequence_position > $2", sql
    assert_equal ["{A}", 5], params
  end

  def test_condition_sql_match_all_with_after
    sql, params = @builder.condition_sql(DcbEventStore::Query.all, 9)
    assert_equal "SELECT COUNT(*) FROM events WHERE sequence_position > $1", sql
    assert_equal [9], params
  end

  # --- namespace ---

  def test_namespaced_builder_reads_and_counts_the_namespaced_table
    builder = DcbEventStore::SqlStore::SqlBuilder.new(DcbEventStore::PostgresStore::Dialect.new, namespace: "billing")

    sql, = builder.read_sql(query([item(event_types: ["A"])]), after: 3)
    assert_equal "SELECT * FROM billing_events WHERE ((type = ANY($1::text[]))) AND sequence_position > $2 " \
                 "ORDER BY sequence_position ASC", sql

    sql, = builder.condition_sql(DcbEventStore::Query.all, nil)
    assert_equal "SELECT COUNT(*) FROM billing_events", sql

    sql, = builder.condition_sql(DcbEventStore::Query.all, 9)
    assert_equal "SELECT COUNT(*) FROM billing_events WHERE sequence_position > $1", sql
  end

  def test_namespace_accepts_a_namespace_object
    namespace = DcbEventStore::Namespace.new("billing")
    builder = DcbEventStore::SqlStore::SqlBuilder.new(DcbEventStore::PostgresStore::Dialect.new, namespace: namespace)

    sql, = builder.read_sql(DcbEventStore::Query.all, after: nil)
    assert_equal "SELECT * FROM billing_events ORDER BY sequence_position ASC", sql
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
    rows, params = @builder.values_clause([event], 2)
    assert_equal [
      "($3::uuid, $4::text, $5::jsonb, $6::text[], $7::uuid, $8::uuid, $9::integer)"
    ], rows
    # Only the event's own parameters come back: the caller already holds the
    # two the offset stands for.
    assert_equal ["id-1", "A", "{}", "{}", nil, nil, 1], params
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

# The same builder with the SQLite dialect: identical statement shapes, SQLite
# fragments. Asserted verbatim next to the PostgreSQL expectations above, so
# the difference between the two backends' SQL is visible in one file.
class TestSqlBuilderSqlite < Minitest::Test
  cover "DcbEventStore::SqlStore::SqlBuilder*"

  TAGS_CONTAIN = "sequence_position IN (SELECT sequence_position FROM event_tags " \
                 "WHERE tag IN (SELECT value FROM json_each(?)) " \
                 "GROUP BY sequence_position HAVING COUNT(*) = ?)".freeze

  def setup
    @builder = DcbEventStore::SqlStore::SqlBuilder.new(DcbEventStore::SqliteStore::Dialect.new)
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
    assert_equal "SELECT * FROM events WHERE sequence_position > ? ORDER BY sequence_position ASC", sql
    assert_equal [7], params
  end

  def test_read_sql_event_types_only
    sql, params = @builder.read_sql(query([item(event_types: %w[A B])]), after: nil)
    expected = "SELECT * FROM events WHERE (type IN (SELECT value FROM json_each(?))) " \
               "ORDER BY sequence_position ASC"
    assert_equal expected, sql
    assert_equal ['["A","B"]'], params
  end

  def test_read_sql_tags_only
    sql, params = @builder.read_sql(query([item(tags: %w[t1 t2])]), after: nil)
    assert_equal "SELECT * FROM events WHERE (#{TAGS_CONTAIN}) ORDER BY sequence_position ASC", sql
    assert_equal ['["t1","t2"]', 2], params
  end

  def test_read_sql_types_and_tags_combined_with_and
    sql, params = @builder.read_sql(query([item(event_types: ["A"], tags: ["t1"])]), after: nil)
    expected = "SELECT * FROM events WHERE (type IN (SELECT value FROM json_each(?)) AND #{TAGS_CONTAIN}) " \
               "ORDER BY sequence_position ASC"
    assert_equal expected, sql
    assert_equal ['["A"]', '["t1"]', 1], params
  end

  def test_read_sql_multiple_items_joined_with_or
    sql, params = @builder.read_sql(query([item(event_types: ["A"]), item(tags: ["t1"])]), after: nil)
    expected = "SELECT * FROM events WHERE (type IN (SELECT value FROM json_each(?))) OR (#{TAGS_CONTAIN}) " \
               "ORDER BY sequence_position ASC"
    assert_equal expected, sql
    assert_equal ['["A"]', '["t1"]', 1], params
  end

  def test_read_sql_query_with_after_wraps_clause
    sql, params = @builder.read_sql(query([item(event_types: ["A"])]), after: 3)
    expected = "SELECT * FROM events WHERE ((type IN (SELECT value FROM json_each(?)))) " \
               "AND sequence_position > ? ORDER BY sequence_position ASC"
    assert_equal expected, sql
    assert_equal ['["A"]', 3], params
  end

  # --- condition_sql ---

  def test_condition_sql_match_all
    sql, params = @builder.condition_sql(DcbEventStore::Query.all, nil)
    assert_equal "SELECT COUNT(*) FROM events", sql
    assert_equal [], params
  end

  def test_condition_sql_with_where
    sql, params = @builder.condition_sql(query([item(event_types: ["A"], tags: ["t1"])]), nil)
    expected = "SELECT COUNT(*) FROM events WHERE (type IN (SELECT value FROM json_each(?)) AND #{TAGS_CONTAIN})"
    assert_equal expected, sql
    assert_equal ['["A"]', '["t1"]', 1], params
  end

  def test_condition_sql_with_after
    sql, params = @builder.condition_sql(query([item(event_types: ["A"])]), 5)
    expected = "SELECT COUNT(*) FROM events WHERE ((type IN (SELECT value FROM json_each(?)))) " \
               "AND sequence_position > ?"
    assert_equal expected, sql
    assert_equal ['["A"]', 5], params
  end

  # The after bound is handed to the tag clause as well, which on SQLite
  # binds it inside the event_tags subquery, before the tag count.
  def test_after_is_passed_into_the_tag_clause
    sql, params = @builder.read_sql(query([item(tags: ["t1"])]), after: 5)
    expected = "SELECT * FROM events WHERE ((sequence_position IN (SELECT sequence_position FROM event_tags " \
               "WHERE tag IN (SELECT value FROM json_each(?)) AND sequence_position > ? " \
               "GROUP BY sequence_position HAVING COUNT(*) = ?))) AND sequence_position > ? " \
               "ORDER BY sequence_position ASC"
    assert_equal expected, sql
    assert_equal ['["t1"]', 5, 1, 5], params
  end

  def test_condition_sql_match_all_with_after
    sql, params = @builder.condition_sql(DcbEventStore::Query.all, 9)
    assert_equal "SELECT COUNT(*) FROM events WHERE sequence_position > ?", sql
    assert_equal [9], params
  end

  # --- values_clause ---

  def test_values_clause_single_event_no_offset
    event = DcbEventStore::Event.new(type: "A", data: { n: 1 }, tags: ["t1"],
                                     id: "id-1", causation_id: "c-1", correlation_id: "r-1")
    rows, params = @builder.values_clause([event], 0)

    assert_equal ["(?, ?, ?, ?, ?, ?, ?)"], rows
    assert_equal ["id-1", "A", '{"n":1}', '["t1"]', "c-1", "r-1", 1], params
  end

  def test_values_clause_respects_param_offset
    event = DcbEventStore::Event.new(type: "A", id: "id-1")
    rows, params = @builder.values_clause([event], 2)

    assert_equal ["(?, ?, ?, ?, ?, ?, ?)"], rows
    assert_equal ["id-1", "A", "{}", "[]", nil, nil, 1], params
  end

  def test_values_clause_multiple_events
    e1 = DcbEventStore::Event.new(type: "A", id: "id-1")
    e2 = DcbEventStore::Event.new(type: "B", id: "id-2")
    rows, params = @builder.values_clause([e1, e2], 0)

    assert_equal ["(?, ?, ?, ?, ?, ?, ?)", "(?, ?, ?, ?, ?, ?, ?)"], rows
    assert_equal 14, params.size
    assert_equal "id-1", params[0]
    assert_equal "id-2", params[7]
  end
end
