# Shared behavioral contract for Upcaster applied on read: a store built with
# an upcaster must transform older event data and report the resulting schema
# version, while a store without one reads the stored version unchanged.
#
# Including classes must set @store in setup and define
# #build_store(upcaster: nil) returning a fresh, empty store.
module UpcasterContract
  def test_old_events_upcasted_on_read
    upcaster = DcbEventStore::Upcaster.new
    upcaster.register("UserCreated", from_version: 1) do |data|
      data.merge(email: "unknown@example.com")
    end
    store = build_store(upcaster: upcaster)

    store.append([DcbEventStore::Event.new(type: "UserCreated", data: {name: "Alice"})])

    event = store.read(DcbEventStore::Query.all).first
    assert_equal "Alice", event.data[:name]
    assert_equal "unknown@example.com", event.data[:email]
    assert_equal 2, event.schema_version
  end

  def test_upcaster_leaves_other_types_alone
    upcaster = DcbEventStore::Upcaster.new
    upcaster.register("UserCreated", from_version: 1) { |data| data.merge(upgraded: true) }
    store = build_store(upcaster: upcaster)

    store.append([DcbEventStore::Event.new(type: "OrderPlaced", data: {amount: 1})])

    event = store.read(DcbEventStore::Query.all).first
    assert_equal({amount: 1}, event.data)
    assert_equal 1, event.schema_version
  end

  def test_schema_version_defaults_to_1
    @store.append([DcbEventStore::Event.new(type: "A")])

    assert_equal 1, @store.read(DcbEventStore::Query.all).first.schema_version
  end
end
