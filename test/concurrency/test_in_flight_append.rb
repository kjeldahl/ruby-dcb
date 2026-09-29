require_relative "../test_helper"
require_relative "../support/postgres_database"
require_relative "../support/in_flight_append"
require "concurrent"

# Issue #42: an append caught in flight (locks held, rows uncommitted) must
# block any append whose condition names a tag it writes, and any append
# writing a tag its own condition names, whichever side is conditional.
class TestInFlightAppend < Minitest::Test
  include PostgresDatabaseHelper
  include InFlightAppendHelper

  cover "DcbEventStore::PostgresStore#acquire_locks!"
  cover "DcbEventStore::PostgresStore#lock_for_import!"

  def setup
    setup_db
  end

  def teardown
    teardown_db
  end

  def query(event_types, tags = [])
    DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: event_types, tags: tags)])
  end

  # Starts +in_flight+ (the arguments of #append, or a callable handed the
  # block to run while its write is in flight, e.g. one calling
  # #with_in_flight_import) and, once it holds its locks and has inserted,
  # runs +racing+ on another connection. Returns what +racing+ produced,
  # having checked it stayed blocked until the in-flight write committed (or,
  # with +blocks: false+, that it did not wait at all). A racing append that
  # does not block is the bug of issue #42: its condition is evaluated
  # against a log missing the in-flight event.
  def race(in_flight:, racing:, blocks: true, racing_namespace: nil)
    racer_conn = PostgresDatabaseHelper.connection
    outcome = Concurrent::Array.new
    racer = nil
    start_in_flight(in_flight) do |release|
      racer = Thread.new do
        racing.call(DcbEventStore::PostgresStore.new(racer_conn, namespace: racing_namespace))
        outcome << :appended
      rescue DcbEventStore::ConditionNotMet
        outcome << :conflict
      end

      racer.join(0.3)
      assert_blocking(outcome, blocks)

      release.call
      racer.join(5)
    end
    outcome.first
  ensure
    racer&.join(5)
    racer_conn&.close
  end

  def start_in_flight(in_flight, &)
    return in_flight.call(&) if in_flight.respond_to?(:call)

    with_in_flight_append(*in_flight, &)
  end

  def assert_blocking(outcome, blocks)
    if blocks
      assert_empty outcome, "racing append did not wait for the in-flight write on the same tag"
    else
      refute_empty outcome, "racing append waited for an in-flight write on another tag"
    end
  end

  # Issue #42: an unconditional append on course:c1 is in flight while a
  # conditional append guards course:c1 from a read that predates it. The
  # condition must wait for the commit and then see the new event.
  def test_unconditional_append_serializes_with_a_condition_on_its_tag
    sub = -> { DcbEventStore::Event.new(type: "Sub", tags: ["course:c1"]) }
    @store.append([sub.call])
    condition = DcbEventStore::AppendCondition.new(fail_if_events_match: query(["Sub"], ["course:c1"]), after: 1)

    outcome = race(in_flight: [[sub.call]], racing: ->(store) { store.append([sub.call], condition) })

    assert_equal :conflict, outcome
    assert_equal [1, 2], @store.read(DcbEventStore::Query.all).map(&:sequence_position)
  end

  # Two conditional appends whose conditions name different tags: the first
  # guards course:c1 and writes an event that also carries student:s1, the
  # tag the second one guards.
  def test_conditions_on_different_tags_serialize_through_a_shared_event_tag
    seat = DcbEventStore::Event.new(type: "Sub", tags: ["student:s1", "course:c1"])
    on_course = DcbEventStore::AppendCondition.new(fail_if_events_match: query(["Sub"], ["course:c1"]))
    on_student = DcbEventStore::AppendCondition.new(fail_if_events_match: query(["Sub"], ["student:s1"]))
    other = DcbEventStore::Event.new(type: "Sub", tags: ["student:s1"])

    outcome = race(in_flight: [[seat], on_course], racing: ->(store) { store.append([other], on_student) })

    assert_equal :conflict, outcome
    assert_equal 1, @store.read(DcbEventStore::Query.all).count
  end

  # A condition naming no tag (type only) can match an event under any tag, so
  # it must wait for every tagged writer, including one whose own condition
  # is scoped to a tag (an unconditional writer already shared its key).
  def test_type_only_condition_serializes_with_a_tagged_conditional_writer
    frozen = DcbEventStore::Event.new(type: "Frozen", tags: ["system:main"])
    on_system = DcbEventStore::AppendCondition.new(fail_if_events_match: query(["Frozen"], ["system:main"]))
    condition = DcbEventStore::AppendCondition.new(fail_if_events_match: query(["Frozen"]))

    outcome = race(in_flight: [[frozen], on_system],
                   racing: ->(store) { store.append([DcbEventStore::Event.new(type: "Op")], condition) })

    assert_equal :conflict, outcome
    assert_equal %w[Frozen], @store.read(DcbEventStore::Query.all).map(&:type)
  end

  # The other side of the guarantee: appends on disjoint tags do not wait for
  # each other, whichever of them is conditional.
  def test_appends_on_disjoint_tags_do_not_block_each_other
    a = DcbEventStore::Event.new(type: "Sub", tags: ["course:a"])
    b = DcbEventStore::Event.new(type: "Sub", tags: ["course:b"])
    on_b = DcbEventStore::AppendCondition.new(fail_if_events_match: query(["Sub"], ["course:b"]))

    outcome = race(in_flight: [[a]], racing: ->(store) { store.append([b], on_b) }, blocks: false)

    assert_equal :appended, outcome
    assert_equal %w[course:a course:b].sort,
                 @store.read(DcbEventStore::Query.all).flat_map(&:tags).sort
  end

  # Namespaces are separate logs, so their lock keys are separate too: an
  # in-flight append on course:c1 in the default namespace does not hold up
  # a conditional append on the very same tag in another namespace, even a
  # type-only condition, which inside one namespace takes the global key
  # exclusively.
  def test_appends_in_different_namespaces_do_not_block_each_other
    DcbEventStore::PostgresStore::Schema.create!(@conn, namespace: "billing")
    sub = -> { DcbEventStore::Event.new(type: "Sub", tags: ["course:c1"]) }
    on_any_sub = DcbEventStore::AppendCondition.new(fail_if_events_match: query(["Sub"]))

    outcome = race(in_flight: [[sub.call]], racing: ->(store) { store.append([sub.call], on_any_sub) },
                   blocks: false, racing_namespace: "billing")

    assert_equal :appended, outcome
    assert_equal 1, DcbEventStore::PostgresStore.new(@conn, namespace: "billing").last_position
  ensure
    DcbEventStore::PostgresStore::Schema.drop!(@conn, namespace: "billing")
  end

  # Issue #58: an import takes its own namespace's write lock, so it holds up
  # an append in that namespace and leaves the default namespace's alone.
  def test_namespaced_import_blocks_its_own_namespace_only
    DcbEventStore::PostgresStore::Schema.create!(@conn, namespace: "billing")
    sub = -> { DcbEventStore::Event.new(type: "Sub", tags: ["course:c1"]) }
    import = lambda do |&run|
      exported = DcbEventStore::SequencedEvent.new(
        sequence_position: 1, type: "Sub", data: {}, tags: ["course:c1"], id: SecureRandom.uuid,
        created_at: Time.now, causation_id: nil, correlation_id: nil, schema_version: 1
      )
      with_in_flight_import([exported], namespace: "billing", &run)
    end

    outcome = race(in_flight: import, racing: ->(store) { store.append([sub.call]) }, racing_namespace: "billing")

    assert_equal :appended, outcome
    assert_equal 2, DcbEventStore::PostgresStore.new(@conn, namespace: "billing").last_position

    outcome = race(in_flight: import, racing: ->(store) { store.append([sub.call]) }, blocks: false)

    assert_equal :appended, outcome
    assert_equal 1, @store.last_position
  ensure
    DcbEventStore::PostgresStore::Schema.drop!(@conn, namespace: "billing")
  end
end
