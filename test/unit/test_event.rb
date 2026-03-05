require_relative "../test_helper"

class TestEvent < Minitest::Test
  def test_creates_with_defaults
    e = DcbEventStore::Event.new(type: "Foo")
    assert_equal "Foo", e.type
    assert_equal({}, e.data)
    assert_equal [], e.tags
    refute_nil e.id
    assert_nil e.causation_id
    assert_nil e.correlation_id
  end

  def test_coerces_type_to_string
    e = DcbEventStore::Event.new(type: :Foo)
    assert_equal "Foo", e.type
  end

  def test_tags_frozen
    e = DcbEventStore::Event.new(type: "Foo", tags: ["a:1"])
    assert e.tags.frozen?
  end

  def test_frozen
    e = DcbEventStore::Event.new(type: "Foo")
    assert e.frozen?
  end

  def test_structural_equality
    id = SecureRandom.uuid
    a = DcbEventStore::Event.new(type: "Foo", data: {x: 1}, tags: ["a:1"], id: id)
    b = DcbEventStore::Event.new(type: "Foo", data: {x: 1}, tags: ["a:1"], id: id)
    assert_equal a, b
  end

  def test_each_event_gets_unique_id
    a = DcbEventStore::Event.new(type: "Foo")
    b = DcbEventStore::Event.new(type: "Foo")
    refute_equal a.id, b.id
  end

  def test_custom_id
    e = DcbEventStore::Event.new(type: "Foo", id: "custom-id")
    assert_equal "custom-id", e.id
  end

  def test_causation_and_correlation
    e = DcbEventStore::Event.new(type: "Foo", causation_id: "c1", correlation_id: "r1")
    assert_equal "c1", e.causation_id
    assert_equal "r1", e.correlation_id
  end
end
