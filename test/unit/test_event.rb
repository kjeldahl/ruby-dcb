require_relative "../test_helper"

class TestEvent < Minitest::Test
  cover "DcbEventStore::Event*"

  def setup
    # Enable validation for these tests
    @original_validation = DcbEventStore.validate_events
    DcbEventStore.validate_events = true
  end

  def teardown
    DcbEventStore.validate_events = @original_validation
  end

  def test_creates_with_defaults
    e = DcbEventStore::Event.new(type: "OrderCreated")
    assert_equal "OrderCreated", e.type
    assert_equal({}, e.data)
    assert_equal [], e.tags
    refute_nil e.id
    assert_nil e.causation_id
    assert_nil e.correlation_id
  end

  def test_coerces_type_to_string
    e = DcbEventStore::Event.new(type: :OrderCreated)
    assert_equal "OrderCreated", e.type
  end

  def test_tags_frozen
    e = DcbEventStore::Event.new(type: "OrderCreated", tags: ["order:123"])
    assert e.tags.frozen?
  end

  def test_frozen
    e = DcbEventStore::Event.new(type: "OrderCreated")
    assert e.frozen?
  end

  def test_structural_equality
    id = SecureRandom.uuid
    a = DcbEventStore::Event.new(type: "OrderCreated", data: {x: 1}, tags: ["order:1"], id: id)
    b = DcbEventStore::Event.new(type: "OrderCreated", data: {x: 1}, tags: ["order:1"], id: id)
    assert_equal a, b
  end

  def test_each_event_gets_unique_id
    a = DcbEventStore::Event.new(type: "OrderCreated")
    b = DcbEventStore::Event.new(type: "OrderCreated")
    refute_equal a.id, b.id
  end

  def test_custom_id
    e = DcbEventStore::Event.new(type: "OrderCreated", id: "custom-id")
    assert_equal "custom-id", e.id
  end

  def test_causation_and_correlation
    e = DcbEventStore::Event.new(type: "OrderCreated", causation_id: "c1", correlation_id: "r1")
    assert_equal "c1", e.causation_id
    assert_equal "r1", e.correlation_id
  end

  # --- Validation tests ---

  def test_validates_type_format
    # Valid type
    e = DcbEventStore::Event.new(type: "OrderCreated")
    assert_equal "OrderCreated", e.type

    # Invalid type - starts with number
    error = assert_raises(DcbEventStore::Validation::ValidationError) do
      DcbEventStore::Event.new(type: "123Invalid")
    end
    assert_equal :type, error.field
  end

  def test_validates_type_not_empty
    error = assert_raises(DcbEventStore::Validation::ValidationError) do
      DcbEventStore::Event.new(type: "")
    end
    assert_equal :type, error.field
  end

  def test_validates_data_is_hash
    error = assert_raises(DcbEventStore::Validation::ValidationError) do
      DcbEventStore::Event.new(type: "OrderCreated", data: "not a hash")
    end
    assert_equal :data, error.field
  end

  def test_validates_tags_no_commas
    error = assert_raises(DcbEventStore::Validation::ValidationError) do
      DcbEventStore::Event.new(type: "OrderCreated", tags: ["tag,with,commas"])
    end
    assert_equal :tags, error.field
  end

  def test_validates_tags_no_braces
    error = assert_raises(DcbEventStore::Validation::ValidationError) do
      DcbEventStore::Event.new(type: "OrderCreated", tags: ["tag{with}braces"])
    end
    assert_equal :tags, error.field
  end

  def test_validates_tags_no_quotes
    error = assert_raises(DcbEventStore::Validation::ValidationError) do
      DcbEventStore::Event.new(type: "OrderCreated", tags: ["tag\"with\"quotes"])
    end
    assert_equal :tags, error.field
  end

  def test_skip_validation_with_validate_false
    # Should not raise even with invalid input when validate: false
    e = DcbEventStore::Event.new(type: "123Invalid", validate: false)
    assert_equal "123Invalid", e.type
  end

  def test_valid_tags_with_colons
    # Colons are allowed in tags
    e = DcbEventStore::Event.new(type: "OrderCreated", tags: ["order:123", "customer:alice"])
    assert_equal ["order:123", "customer:alice"], e.tags
  end

  def test_valid_tags_with_hyphens
    # Hyphens are allowed in tags
    e = DcbEventStore::Event.new(type: "OrderCreated", tags: ["order-123"])
    assert_equal ["order-123"], e.tags
  end
end
