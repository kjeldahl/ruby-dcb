require_relative "../test_helper"

# The SQLite dialect is what makes SqlBuilder's statements SQLite: every
# fragment is asserted verbatim, together with the bind parameters the clause
# builders push onto the array they are handed.
class TestSqliteDialect < Minitest::Test
  cover "DcbEventStore::SqliteStore::Dialect*"

  def setup
    @dialect = DcbEventStore::SqliteStore::Dialect.new
  end

  def event(**attrs)
    DcbEventStore::Event.new(type: "A", data: { n: 1 }, tags: ["t1"],
                             id: "id-1", causation_id: "c-1", correlation_id: "r-1", **attrs)
  end

  # --- placeholder ---

  def test_placeholder_is_positional_whatever_the_index
    assert_equal "?", @dialect.placeholder(1)
    assert_equal "?", @dialect.placeholder(7)
  end

  # --- type_in ---

  def test_type_in_binds_the_list_as_json
    params = []
    assert_equal "type IN (SELECT value FROM json_each(?))", @dialect.type_in(params, %w[A B])
    assert_equal ['["A","B"]'], params
  end

  def test_type_in_appends_to_the_params_already_collected
    params = %w[x y]
    assert_equal "type IN (SELECT value FROM json_each(?))", @dialect.type_in(params, ["A"])
    assert_equal ["x", "y", '["A"]'], params
  end

  # --- tags_contain ---

  def test_tags_contain_binds_the_list_and_the_number_of_tags
    params = []
    expected = "sequence_position IN (SELECT sequence_position FROM event_tags " \
               "WHERE tag IN (SELECT value FROM json_each(?)) " \
               "GROUP BY sequence_position HAVING COUNT(*) = ?)"

    assert_equal expected, @dialect.tags_contain(params, %w[t1 t2])
    assert_equal ['["t1","t2"]', 2], params
  end

  def test_tags_contain_appends_to_the_params_already_collected
    params = ["x"]
    @dialect.tags_contain(params, ["t1"])
    assert_equal ["x", '["t1"]', 1], params
  end

  # The count is compared against the number of distinct tags an event has in
  # the index table, so a repeated tag must not inflate it.
  def test_tags_contain_deduplicates_the_tags
    params = []
    @dialect.tags_contain(params, %w[t1 t1 t2])
    assert_equal ['["t1","t2"]', 2], params
  end

  # --- after_clause ---

  def test_after_clause_binds_the_position
    params = []
    assert_equal "sequence_position > ?", @dialect.after_clause(params, 7)
    assert_equal [7], params
  end

  def test_after_clause_appends_to_the_params_already_collected
    params = %w[x y]
    assert_equal "sequence_position > ?", @dialect.after_clause(params, 4)
    assert_equal ["x", "y", 4], params
  end

  # --- insert_row ---

  def test_insert_row_is_uncast_and_appends_the_params
    params = []
    row = @dialect.insert_row(params, event)

    assert_equal "(?, ?, ?, ?, ?, ?, ?)", row
    assert_equal ["id-1", "A", '{"n":1}', '["t1"]', "c-1", "r-1", 1], params
  end

  def test_insert_row_of_several_events_appends_each
    params = %w[x y]
    first = @dialect.insert_row(params, event)
    second = @dialect.insert_row(params, event(id: "id-2"))

    assert_equal "(?, ?, ?, ?, ?, ?, ?)", first
    assert_equal "(?, ?, ?, ?, ?, ?, ?)", second
    assert_equal 16, params.size
    assert_equal "id-1", params[2]
    assert_equal "id-2", params[9]
  end

  # --- insert_sql / insert_tag_sql / insert_params ---

  def test_insert_sql
    expected = <<~SQL
      INSERT INTO events (event_id, type, data, tags, causation_id, correlation_id, schema_version)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(event_id) DO NOTHING
      RETURNING sequence_position, created_at
    SQL
    assert_equal expected, @dialect.insert_sql
  end

  def test_insert_tag_sql
    assert_equal "INSERT INTO event_tags (tag, sequence_position) VALUES (?, ?)", @dialect.insert_tag_sql
  end

  def test_insert_params_are_in_column_order
    assert_equal ["id-1", "A", '{"n":1}', '["t1"]', "c-1", "r-1", 1], @dialect.insert_params(event)
  end

  def test_insert_params_of_a_bare_event
    bare = DcbEventStore::Event.new(type: "B", id: "id-2")
    assert_equal ["id-2", "B", "{}", "[]", nil, nil, 1], @dialect.insert_params(bare)
  end

  # --- encode_list / decode_list ---

  def test_encode_list_writes_a_json_array_of_strings
    assert_equal "[]", @dialect.encode_list([])
    assert_equal '["a","b"]', @dialect.encode_list(%w[a b])
    assert_equal '["a,b"]', @dialect.encode_list(["a,b"])
    assert_equal '["a","1"]', @dialect.encode_list([:a, 1])
  end

  def test_decode_list_reads_a_json_array
    assert_equal [], @dialect.decode_list(nil)
    assert_equal [], @dialect.decode_list("[]")
    assert_equal %w[a b], @dialect.decode_list('["a","b"]')
    assert_equal ["a,b"], @dialect.decode_list('["a,b"]')
  end
end
