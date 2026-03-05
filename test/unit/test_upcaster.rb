require_relative "../test_helper"

class TestUpcaster < Minitest::Test
  def test_no_transformers_returns_same
    u = DcbEventStore::Upcaster.new
    data, version = u.upcast("Foo", {x: 1}, 1)
    assert_equal({x: 1}, data)
    assert_equal 1, version
  end

  def test_single_upcast
    u = DcbEventStore::Upcaster.new
    u.register("Foo", from_version: 1) { |data| data.merge(y: 2) }

    data, version = u.upcast("Foo", {x: 1}, 1)
    assert_equal({x: 1, y: 2}, data)
    assert_equal 2, version
  end

  def test_chained_upcast
    u = DcbEventStore::Upcaster.new
    u.register("Foo", from_version: 1) { |data| data.merge(y: 2) }
    u.register("Foo", from_version: 2) { |data| data.merge(z: 3) }

    data, version = u.upcast("Foo", {x: 1}, 1)
    assert_equal({x: 1, y: 2, z: 3}, data)
    assert_equal 3, version
  end

  def test_upcast_only_matches_type
    u = DcbEventStore::Upcaster.new
    u.register("Bar", from_version: 1) { |data| data.merge(y: 2) }

    data, version = u.upcast("Foo", {x: 1}, 1)
    assert_equal({x: 1}, data)
    assert_equal 1, version
  end
end
