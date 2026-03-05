require_relative "../test_helper"
require_relative "../support/database"

class TestUpcasterIntegration < Minitest::Test
  include DatabaseHelper

  def setup
    setup_db
  end

  def teardown
    teardown_db
  end

  def test_old_events_upcasted_on_read
    @store.append([DcbEventStore::Event.new(type: "UserCreated", data: {name: "Alice"})])

    upcaster = DcbEventStore::Upcaster.new
    upcaster.register("UserCreated", from_version: 1) do |data|
      data.merge(email: "unknown@example.com")
    end

    store_with_upcaster = DcbEventStore::Store.new(@conn, upcaster: upcaster)
    event = store_with_upcaster.read(DcbEventStore::Query.all).first

    assert_equal "Alice", event.data[:name]
    assert_equal "unknown@example.com", event.data[:email]
    assert_equal 2, event.schema_version
  end

  def test_schema_version_defaults_to_1
    @store.append([DcbEventStore::Event.new(type: "A")])
    read = @store.read(DcbEventStore::Query.all).first
    assert_equal 1, read.schema_version
  end
end
