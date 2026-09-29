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
    assert_equal "events_tx_offset", ns.tx_offset_function
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
    assert_equal "billing_events_tx_offset", ns.tx_offset_function
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

  def test_lock_offset_zero_is_the_default_namespaces_alone
    Zlib.stub(:crc32, 0) do
      ns = Namespace.new("zero_hash")

      assert_equal 1 << 32, ns.lock_offset
    end
    assert_equal 0, Namespace.new.lock_offset
  end

  def test_names_sharing_a_lock_offset_publish_a_collision_once_naming_both
    shared = rand((2**20)..(2**30)) # fresh per run: the registry lives as long as the process
    events = collect_events do
      Zlib.stub(:crc32, shared) do
        Namespace.new("collide_a")
        Namespace.new("collide_b")
        Namespace.new("collide_b")
        Namespace.new("collide_c")
      end
    end

    assert_equal ["namespace_collision.dcb"] * 2, events.map(&:name)
    assert_equal({ namespace: "collide_b", shares_with: ["collide_a"], lock_offset: shared << 32 },
                 events.first.payload)
    assert_equal({ namespace: "collide_c", shares_with: %w[collide_a collide_b], lock_offset: shared << 32 },
                 events.last.payload)
  end

  def test_distinct_lock_offsets_publish_nothing
    events = collect_events do
      Namespace.new("billing")
      Namespace.new("shipping")
    end

    assert_empty events
  end

  def test_offset_registry_is_guarded_by_its_lock
    lock = Namespace.const_get(:OFFSET_OWNERS_LOCK, false)
    built = nil
    lock.synchronize do
      thread = Thread.new { built = Namespace.new("guarded_by_lock") }
      sleep 0.05

      assert_nil built, "construction waits for the registry lock"
      lock.unlock
      thread.join
      lock.lock
    end

    assert_equal "guarded_by_lock", built.name
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

  def test_the_length_limit_keeps_the_sequence_name_within_postgres_63_bytes
    name = "a" * Namespace::MAX_NAME_LENGTH

    assert_operator "#{name}_events_sequence_position_seq".length, :<=, 63
    assert_operator "idx_#{name}_events_correlation_id".length, :<=, 63
    assert_operator "#{name}_projection_snapshots_pkey".length, :<=, 63
  end

  def test_rejects_names_sqlite_reserves_as_a_table_prefix
    %w[sqlite sqlite_ sqlite_x].each do |bad|
      error = assert_raises(ArgumentError, bad) { Namespace.new(bad) }

      assert_includes error.message, bad.inspect
      assert_includes error.message, "reserved"
    end
    %w[sqlitex sqlite2 my_sqlite].each { |ok| assert_equal ok, Namespace.new(ok).name }
  end

  def test_longest_name_keeps_every_identifier_under_postgres_limit
    ns = Namespace.new("a" * Namespace::MAX_NAME_LENGTH)

    [ns.events_table, ns.event_tags_table, ns.snapshots_table, ns.channel, ns.tx_offset_function,
     "idx_#{ns.events_table}_correlation_id"].each do |identifier|
      assert_operator identifier.bytesize, :<=, 63, identifier
    end
  end

  # --- wrap ---

  def test_wrap_passes_a_namespace_through
    ns = Namespace.new("billing")

    assert_same ns, Namespace.wrap(ns)
  end

  # A subclass is a Namespace too: passed through as it is, not rebuilt.
  def test_wrap_passes_a_subclass_instance_through
    sub = Class.new(Namespace).new("billing")

    assert_same sub, Namespace.wrap(sub)
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

  def test_equality_holds_across_subclasses
    sub = Class.new(Namespace).new("billing")

    assert_equal Namespace.new("billing"), sub
    assert_equal sub, Namespace.new("billing")
  end

  def test_to_s_is_the_name_or_empty
    assert_equal "billing", Namespace.new("billing").to_s
    assert_equal "", Namespace.new.to_s
  end

  def test_inspect_names_the_namespace
    assert_equal "#<DcbEventStore::Namespace billing>", Namespace.new("billing").inspect
    assert_equal "#<DcbEventStore::Namespace default>", Namespace.new.inspect
  end

  private

  def collect_events
    events = []
    previous = DcbEventStore.instrumentation
    DcbEventStore.instrumentation = DcbEventStore::Notifications.new
    DcbEventStore.instrumentation.subscribe { |event| events << event }
    yield
    events
  ensure
    DcbEventStore.instrumentation = previous
  end
end
