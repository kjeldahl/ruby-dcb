require_relative "../test_helper"
require "zlib"

# Namespace: the value that turns a name into the table, channel and
# lock-key names a store in that namespace uses, and that rejects any name
# that could not be spliced into SQL identifiers.
class TestNamespace < Minitest::Test
  cover "DcbEventStore::Namespace*"

  Namespace = DcbEventStore::Namespace

  # --- default ---

  def test_default_prefixes_nothing
    ns = Namespace.new

    assert_predicate ns, :default?
    assert_nil ns.name
    assert_equal "events", ns.events_table
    assert_equal "event_tags", ns.event_tags_table
    assert_equal "projection_snapshots", ns.snapshots_table
    assert_equal "events_appended", ns.channel
    assert_equal 0, ns.lock_offset
  end

  def test_default_constant_is_the_default_namespace
    assert_predicate Namespace::DEFAULT, :default?
    assert_equal Namespace.new, Namespace::DEFAULT
  end

  # --- named ---

  def test_named_prefixes_every_object
    ns = Namespace.new("billing")

    refute_predicate ns, :default?
    assert_equal "billing", ns.name
    assert_equal "billing_events", ns.events_table
    assert_equal "billing_event_tags", ns.event_tags_table
    assert_equal "billing_projection_snapshots", ns.snapshots_table
    assert_equal "billing_events_appended", ns.channel
  end

  def test_table_joins_the_name_to_any_base
    assert_equal "billing_x", Namespace.new("billing").table("x")
    assert_equal "x", Namespace.new.table("x")
  end

  def test_symbol_names_are_accepted
    assert_equal "billing", Namespace.new(:billing).name
  end

  def test_name_is_frozen
    assert_predicate Namespace.new("billing").name, :frozen?
    assert_predicate Namespace.new("billing"), :frozen?
  end

  # --- lock_offset ---

  def test_lock_offset_puts_the_name_hash_above_the_tag_bits
    ns = Namespace.new("billing")

    assert_equal (Zlib.crc32("billing") & 0x7FFF_FFFF) << 32, ns.lock_offset
    assert_equal 0, ns.lock_offset & 0xFFFF_FFFF, "the low 32 bits are the tag's"
  end

  def test_lock_offset_plus_any_tag_key_fits_a_signed_bigint
    max_tag_key = 0xFFFF_FFFF
    ["billing", "shipping", "a", "z_9", "a" * Namespace::MAX_NAME_LENGTH].each do |name|
      key = Namespace.new(name).lock_offset + max_tag_key

      assert_operator key, :<=, (2**63) - 1, name
      assert_operator key, :>=, 0, name
    end
  end

  def test_lock_offset_is_stable_and_differs_between_names
    assert_equal Namespace.new("billing").lock_offset, Namespace.new("billing").lock_offset
    refute_equal Namespace.new("billing").lock_offset, Namespace.new("shipping").lock_offset
  end

  # --- validation ---

  def test_rejects_names_that_are_not_identifiers
    ["Billing", "1billing", "bill-ing", "bill ing", "bill;ing", "", "bill.ing", "événements"].each do |bad|
      error = assert_raises(ArgumentError, bad) { Namespace.new(bad) }

      assert_includes error.message, bad.inspect
      assert_includes error.message, Namespace::NAME_PATTERN.inspect
    end
  end

  def test_rejects_names_over_the_length_limit
    Namespace.new("a" * Namespace::MAX_NAME_LENGTH)
    too_long = "a" * (Namespace::MAX_NAME_LENGTH + 1)
    error = assert_raises(ArgumentError) { Namespace.new(too_long) }

    assert_includes error.message, too_long.inspect
    assert_includes error.message, "longer than #{Namespace::MAX_NAME_LENGTH}"
  end

  def test_longest_name_keeps_every_identifier_under_postgres_limit
    ns = Namespace.new("a" * Namespace::MAX_NAME_LENGTH)

    [ns.events_table, ns.event_tags_table, ns.snapshots_table, ns.channel,
     "idx_#{ns.events_table}_correlation_id"].each do |identifier|
      assert_operator identifier.bytesize, :<=, 63, identifier
    end
  end

  # --- wrap ---

  def test_wrap_passes_a_namespace_through
    ns = Namespace.new("billing")

    assert_same ns, Namespace.wrap(ns)
  end

  def test_wrap_builds_from_nil_or_a_name
    assert_equal Namespace::DEFAULT, Namespace.wrap(nil)
    assert_equal Namespace.new("billing"), Namespace.wrap("billing")
    assert_equal Namespace.new("billing"), Namespace.wrap(:billing)
  end

  def test_wrap_validates
    assert_raises(ArgumentError) { Namespace.wrap("Bad Name") }
  end

  # --- value semantics ---

  def test_equality_is_by_name
    assert_equal Namespace.new("billing"), Namespace.new("billing")
    refute_equal Namespace.new("billing"), Namespace.new("shipping")
    refute_equal Namespace.new("billing"), Namespace.new
    refute_equal Namespace.new("billing"), "billing"
    assert_equal Namespace.new("billing").hash, Namespace.new("billing").hash
    assert_equal 1, [Namespace.new("billing"), Namespace.new("billing")].uniq.size
    assert Namespace.new("billing").eql?(Namespace.new("billing"))
  end

  def test_to_s_is_the_name_or_empty
    assert_equal "billing", Namespace.new("billing").to_s
    assert_equal "", Namespace.new.to_s
  end

  def test_inspect_names_the_namespace
    assert_equal "#<DcbEventStore::Namespace billing>", Namespace.new("billing").inspect
    assert_equal "#<DcbEventStore::Namespace default>", Namespace.new.inspect
  end
end
