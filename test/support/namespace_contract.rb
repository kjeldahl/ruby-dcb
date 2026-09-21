# Shared contract for the SQL backends' namespaces: two stores on one
# database in different namespaces are two independent event logs, with their
# own sequence, their own consistency checks and their own snapshots.
#
# Including classes run setup_db (so @store is a store in the default
# namespace on a database the schema is installed on) and define
# build_namespaced_store(name), which installs the schema for +name+ on the
# same database if needed and returns a store in it, and
# build_namespaced_snapshot_store(name).
module NamespaceContract
  def event(type = "A", tags: ["t:1"], **attrs)
    DcbEventStore::Event.new(type: type, tags: tags, **attrs)
  end

  def tagged(*tags)
    DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: [], tags: tags)])
  end

  def test_store_exposes_its_namespace
    assert_predicate @store.namespace, :default?
    assert_equal "billing", build_namespaced_store("billing").namespace.name
  end

  def test_namespace_name_is_validated
    assert_raises(ArgumentError) { build_namespaced_store("Bad Name") }
  end

  def test_appends_in_one_namespace_are_invisible_in_another
    billing = build_namespaced_store("billing")
    shipping = build_namespaced_store("shipping")

    @store.append([event("Default")])
    billing.append([event("Billed"), event("Billed")])
    shipping.append([event("Shipped")])

    assert_equal ["Default"], @store.read(DcbEventStore::Query.all).map(&:type)
    assert_equal %w[Billed Billed], billing.read(DcbEventStore::Query.all).map(&:type)
    assert_equal ["Shipped"], shipping.read(DcbEventStore::Query.all).map(&:type)
  end

  def test_each_namespace_has_its_own_sequence
    billing = build_namespaced_store("billing")

    @store.append([event, event, event])
    appended = billing.append([event])

    assert_equal 1, appended[0].sequence_position
    assert_equal 1, billing.last_position
    assert_equal 3, @store.last_position
  end

  def test_last_position_is_nil_on_an_empty_namespace
    billing = build_namespaced_store("billing")
    @store.append([event])

    assert_nil billing.last_position
  end

  def test_a_condition_only_sees_its_own_namespace
    billing = build_namespaced_store("billing")
    @store.append([event("Sub", tags: ["course:c1"])])
    condition = DcbEventStore::AppendCondition.new(fail_if_events_match: tagged("course:c1"))

    # The default namespace has a course:c1 event, billing does not: the
    # same condition fails on one and passes on the other.
    assert_raises(DcbEventStore::ConditionNotMet) { @store.append([event("Sub", tags: ["course:c1"])], condition) }
    assert_equal 1, billing.append([event("Sub", tags: ["course:c1"])], condition).size
    assert_raises(DcbEventStore::ConditionNotMet) { billing.append([event("Sub", tags: ["course:c1"])], condition) }
  end

  def test_tag_reads_stay_inside_the_namespace
    billing = build_namespaced_store("billing")
    @store.append([event("Default", tags: ["course:c1"])])
    billing.append([event("Billed", tags: ["course:c1"]), event("Other", tags: ["course:c2"])])

    assert_equal ["Billed"], billing.read(tagged("course:c1")).map(&:type)
    assert_equal ["Default"], @store.read(tagged("course:c1")).map(&:type)
    assert_equal ["Billed"], billing.read_from(tagged("course:c1"), after: 0).map(&:type)
  end

  def test_the_same_event_id_can_be_stored_in_two_namespaces
    billing = build_namespaced_store("billing")
    id = "11111111-1111-4111-8111-111111111111"

    assert_equal 1, @store.append([event(id: id)]).size
    assert_equal 1, billing.append([event(id: id)]).size
    assert_empty billing.append([event(id: id)]), "a re-append inside the namespace is still skipped"
  end

  def test_snapshots_are_per_namespace
    default_snapshots = build_namespaced_snapshot_store(nil)
    billing_snapshots = build_namespaced_snapshot_store("billing")

    default_snapshots.store("k", position: 1, state: { n: 1 })
    billing_snapshots.store("k", position: 2, state: { n: 2 })

    assert_equal 1, default_snapshots.fetch("k").position
    assert_equal 2, billing_snapshots.fetch("k").position

    billing_snapshots.clear

    assert_nil billing_snapshots.fetch("k")
    assert_equal 1, default_snapshots.fetch("k").position
  end

  def test_decision_model_snapshots_in_a_namespace
    billing = build_namespaced_store("billing")
    snapshots = build_namespaced_snapshot_store("billing")
    projection = DcbEventStore::Projection.new(
      query: tagged("course:c1"), initial_state: 0, handlers: { "Sub" => ->(state, _event) { state + 1 } },
      snapshot: DcbEventStore::Snapshot.new(name: "count", version: 1, every: 1)
    )

    billing.append([event("Sub", tags: ["course:c1"]), event("Sub", tags: ["course:c1"])])
    @store.append([event("Sub", tags: ["course:c1"])])

    model = DcbEventStore::DecisionModel.build(billing, snapshots: snapshots, count: projection)

    assert_equal 2, model.states[:count]
    assert_equal 2, snapshots.fetch(projection.snapshot.key(projection.query)).position
    assert_nil build_namespaced_snapshot_store(nil).fetch(projection.snapshot.key(projection.query))
  end

  def test_schema_create_is_idempotent_per_namespace
    billing = build_namespaced_store("billing")
    billing.append([event])

    build_namespaced_store("billing") # installs the schema again

    assert_equal 1, billing.read(DcbEventStore::Query.all).to_a.size
  end
end
