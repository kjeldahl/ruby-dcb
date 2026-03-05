require_relative "../test_helper"

class TestEvent < Minitest::Test
  def test_creates_with_defaults
    e = DcbEventStore::Event.new(type: "Foo")
    assert_equal "Foo", e.type
    assert_equal({}, e.data)
    assert_equal [], e.tags
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
    a = DcbEventStore::Event.new(type: "Foo", data: {x: 1}, tags: ["a:1"])
    b = DcbEventStore::Event.new(type: "Foo", data: {x: 1}, tags: ["a:1"])
    assert_equal a, b
  end
end
