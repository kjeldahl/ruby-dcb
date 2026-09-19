require_relative "../test_helper"

# Unit tests for the Snapshot configuration object: the key a projection's
# snapshot is stored under, the +every+ write-policy validation, and the
# dump/load pair the state travels through.
class TestSnapshot < Minitest::Test
  cover "DcbEventStore::Snapshot*"

  def query(types: ["Increment"], tags: ["counter:a"])
    DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: types, tags: tags)])
  end

  # --- key ---

  # The query part is Query#fingerprint, not its log rendering, so a tag
  # containing a comma cannot make two different queries share a key.
  def test_key_is_name_version_and_query_fingerprint
    snapshot = DcbEventStore::Snapshot.new(name: "count")

    assert_equal 'count/v1/[[["Increment"],["counter:a"]]]', snapshot.key(query)
  end

  def test_key_carries_the_version
    assert_equal 'count/v7/[[["Increment"],["counter:a"]]]',
                 DcbEventStore::Snapshot.new(name: "count", version: 7).key(query)
  end

  def test_key_renders_an_unbounded_query
    assert_equal "count/v1/[]", DcbEventStore::Snapshot.new(name: "count").key(DcbEventStore::Query.all)
  end

  def test_key_renders_every_query_item
    multi = DcbEventStore::Query.new([
                                       DcbEventStore::QueryItem.new(event_types: %w[A B], tags: ["t:1"]),
                                       DcbEventStore::QueryItem.new(event_types: [], tags: ["t:2"])
                                     ])

    assert_equal 'count/v1/[[["A","B"],["t:1"]],[[],["t:2"]]]',
                 DcbEventStore::Snapshot.new(name: "count").key(multi)
  end

  # Two queries that render alike for a log ("Query[E{a,b}]") must still get
  # separate keys.
  def test_key_separates_queries_that_render_alike
    two_tags = DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: ["E"], tags: %w[a b])])
    one_tag = DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: ["E"], tags: ["a,b"])])
    snapshot = DcbEventStore::Snapshot.new(name: "count")

    assert_equal two_tags.to_s, one_tag.to_s
    refute_equal snapshot.key(two_tags), snapshot.key(one_tag)
  end

  # The tags are part of the key, so every entity gets its own snapshot from
  # one configuration.
  def test_key_differs_per_query
    snapshot = DcbEventStore::Snapshot.new(name: "count")

    refute_equal snapshot.key(query(tags: ["counter:a"])), snapshot.key(query(tags: ["counter:b"]))
  end

  def test_key_differs_per_name_and_version
    refute_equal DcbEventStore::Snapshot.new(name: "a").key(query),
                 DcbEventStore::Snapshot.new(name: "b").key(query)
    refute_equal DcbEventStore::Snapshot.new(name: "a", version: 1).key(query),
                 DcbEventStore::Snapshot.new(name: "a", version: 2).key(query)
  end

  def test_name_is_stringified
    snapshot = DcbEventStore::Snapshot.new(name: :count)

    assert_equal "count", snapshot.name
    assert_equal "count/v1/[]", snapshot.key(DcbEventStore::Query.all)
  end

  def test_version_may_be_a_string
    snapshot = DcbEventStore::Snapshot.new(name: "count", version: "2024-01-01")

    assert_equal "2024-01-01", snapshot.version
    assert_equal "count/v2024-01-01/[]", snapshot.key(DcbEventStore::Query.all)
  end

  # --- every ---

  def test_every_defaults_to_one
    assert_equal 1, DcbEventStore::Snapshot.new(name: "count").every
  end

  def test_every_is_kept
    assert_equal 25, DcbEventStore::Snapshot.new(name: "count", every: 25).every
  end

  def test_every_below_one_is_rejected
    [0, -1, -100].each do |every|
      error = assert_raises(ArgumentError) { DcbEventStore::Snapshot.new(name: "count", every: every) }
      assert_equal "every must be >= 1", error.message
    end
  end

  def test_every_of_one_is_accepted
    assert_equal 1, DcbEventStore::Snapshot.new(name: "count", every: 1).every
  end

  # --- defaults and accessors ---

  def test_version_defaults_to_one
    assert_equal 1, DcbEventStore::Snapshot.new(name: "count").version
  end

  # --- dump / load ---

  def test_default_dump_and_load_are_the_identity
    snapshot = DcbEventStore::Snapshot.new(name: "count")
    state = { n: 1, items: [1, 2] }

    assert_same state, snapshot.dump(state)
    assert_same state, snapshot.load(state)
  end

  def test_default_dump_and_load_pass_nil_and_false_through
    snapshot = DcbEventStore::Snapshot.new(name: "count")

    assert_nil snapshot.dump(nil)
    assert_nil snapshot.load(nil)
    assert_equal false, snapshot.dump(false)
    assert_equal false, snapshot.load(false)
  end

  def test_dump_and_load_use_the_supplied_pair
    snapshot = DcbEventStore::Snapshot.new(
      name: "count",
      dump: ->(state) { state.to_a },
      load: ->(pairs) { pairs.to_h }
    )

    assert_equal [[:n, 1]], snapshot.dump({ n: 1 })
    assert_equal({ n: 1 }, snapshot.load([[:n, 1]]))
  end

  def test_only_dump_may_be_supplied
    snapshot = DcbEventStore::Snapshot.new(name: "count", dump: ->(state) { state * 2 })

    assert_equal 6, snapshot.dump(3)
    assert_equal 3, snapshot.load(3)
  end

  def test_only_load_may_be_supplied
    snapshot = DcbEventStore::Snapshot.new(name: "count", load: ->(state) { state * 2 })

    assert_equal 3, snapshot.dump(3)
    assert_equal 6, snapshot.load(3)
  end

  def test_dump_and_load_round_trip_a_struct
    balance = Struct.new(:amount)
    snapshot = DcbEventStore::Snapshot.new(
      name: "balance",
      dump: ->(state) { { amount: state.amount } },
      load: ->(hash) { balance.new(hash.fetch(:amount)) }
    )

    assert_equal balance.new(7), snapshot.load(snapshot.dump(balance.new(7)))
  end

  # --- Entry ---

  def test_entry_carries_position_and_state
    entry = DcbEventStore::Snapshot::Entry.new(position: 12, state: { n: 3 })

    assert_equal 12, entry.position
    assert_equal({ n: 3 }, entry.state)
  end

  def test_entries_compare_by_value
    assert_equal DcbEventStore::Snapshot::Entry.new(position: 1, state: 2),
                 DcbEventStore::Snapshot::Entry.new(position: 1, state: 2)
    refute_equal DcbEventStore::Snapshot::Entry.new(position: 1, state: 2),
                 DcbEventStore::Snapshot::Entry.new(position: 2, state: 2)
  end
end
