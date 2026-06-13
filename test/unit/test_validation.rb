require "test_helper"

class TestValidation < Minitest::Test
  cover "DcbEventStore::Validation*"

  def setup
    # Enable validation for these tests
    @original_validation = DcbEventStore.validate_events
    DcbEventStore.validate_events = true
  end

  def teardown
    DcbEventStore.validate_events = @original_validation
  end

  def test_validate_type_valid
    assert_equal "OrderCreated", DcbEventStore::Validation.validate_type("OrderCreated")
    assert_equal "order_created", DcbEventStore::Validation.validate_type("order_created")
    assert_equal "Order:Created", DcbEventStore::Validation.validate_type("Order:Created")
    assert_equal "Order.Created", DcbEventStore::Validation.validate_type("Order.Created")
    assert_equal "order-created", DcbEventStore::Validation.validate_type("order-created")
    assert_equal "Order123", DcbEventStore::Validation.validate_type("Order123")
  end

  def test_validate_type_empty
    error = assert_raises(DcbEventStore::Validation::ValidationError) do
      DcbEventStore::Validation.validate_type("")
    end
    assert_equal :type, error.field
    assert_includes error.message, "cannot be empty"
  end

  def test_validate_type_too_long
    long_type = "a" * 256
    error = assert_raises(DcbEventStore::Validation::ValidationError) do
      DcbEventStore::Validation.validate_type(long_type)
    end
    assert_equal :type, error.field
    assert_includes error.message, "exceeds maximum length"
  end

  def test_validate_type_starts_with_number
    error = assert_raises(DcbEventStore::Validation::ValidationError) do
      DcbEventStore::Validation.validate_type("123Order")
    end
    assert_equal :type, error.field
    assert_includes error.message, "must start with a letter"
  end

  def test_validate_type_invalid_characters
    error = assert_raises(DcbEventStore::Validation::ValidationError) do
      DcbEventStore::Validation.validate_type("Order@Created")
    end
    assert_equal :type, error.field
    assert_includes error.message, "invalid characters"
  end

  def test_validate_type_with_spaces
    error = assert_raises(DcbEventStore::Validation::ValidationError) do
      DcbEventStore::Validation.validate_type("Order Created")
    end
    assert_equal :type, error.field
    assert_includes error.message, "invalid characters"
  end

  # --- Tags validation ---

  def test_validate_tags_valid
    tags = ["student:alice", "course:math-101", "tenant:acme"]
    assert_equal tags, DcbEventStore::Validation.validate_tags(tags)
  end

  def test_validate_tags_empty
    assert_equal [], DcbEventStore::Validation.validate_tags([])
  end

  def test_validate_tags_with_empty_strings
    # Empty strings are allowed as tags
    assert_equal ["", "tag1"], DcbEventStore::Validation.validate_tags(["", "tag1"])
  end

  def test_validate_tags_too_many
    tags = Array.new(101, "tag")
    error = assert_raises(DcbEventStore::Validation::ValidationError) do
      DcbEventStore::Validation.validate_tags(tags)
    end
    assert_equal :tags, error.field
    assert_includes error.message, "exceeds maximum count"
  end

  def test_validate_tags_individual_too_long
    long_tag = "a" * 256
    error = assert_raises(DcbEventStore::Validation::ValidationError) do
      DcbEventStore::Validation.validate_tags([long_tag])
    end
    assert_equal :tags, error.field
    assert_includes error.message, "exceeds maximum length"
  end

  def test_validate_tags_with_comma
    error = assert_raises(DcbEventStore::Validation::ValidationError) do
      DcbEventStore::Validation.validate_tags(["tag,with,commas"])
    end
    assert_equal :tags, error.field
    assert_includes error.message, "invalid characters"
  end

  def test_validate_tags_with_brace
    error = assert_raises(DcbEventStore::Validation::ValidationError) do
      DcbEventStore::Validation.validate_tags(["tag{with}braces"])
    end
    assert_equal :tags, error.field
    assert_includes error.message, "invalid characters"
  end

  def test_validate_tags_with_quote
    error = assert_raises(DcbEventStore::Validation::ValidationError) do
      DcbEventStore::Validation.validate_tags(["tag\"with\"quotes"])
    end
    assert_equal :tags, error.field
    assert_includes error.message, "invalid characters"
  end

  def test_validate_tags_with_colon
    # Colons are allowed in tags
    assert_equal ["student:alice"], DcbEventStore::Validation.validate_tags(["student:alice"])
  end

  def test_validate_tags_with_hyphen
    # Hyphens are allowed in tags
    assert_equal ["course-101"], DcbEventStore::Validation.validate_tags(["course-101"])
  end

  # --- Data validation ---

  def test_validate_data_valid
    data = { order_id: "123", amount: 100, items: [{ name: "item1", price: 10 }] }
    assert_equal data, DcbEventStore::Validation.validate_data(data)
  end

  def test_validate_data_empty_hash
    assert_equal({}, DcbEventStore::Validation.validate_data({}))
  end

  def test_validate_data_nil
    assert_equal({}, DcbEventStore::Validation.validate_data(nil))
  end

  def test_validate_data_not_hash
    error = assert_raises(DcbEventStore::Validation::ValidationError) do
      DcbEventStore::Validation.validate_data("not a hash")
    end
    assert_equal :data, error.field
    assert_includes error.message, "must be a Hash"
  end

  def test_validate_data_too_large
    # Create data that exceeds 1MB when serialized
    large_data = { data: "x" * (1_000_000 / 2) } # Will be > 1MB when JSON serialized
    error = assert_raises(DcbEventStore::Validation::ValidationError) do
      DcbEventStore::Validation.validate_data(large_data)
    end
    assert_equal :data, error.field
    assert_includes error.message, "exceeds maximum size"
  end

  # --- Full event validation ---

  def test_validate_event_valid
    DcbEventStore::Validation.validate_event(
      type: "OrderCreated",
      data: { order_id: "123" },
      tags: ["order:123", "customer:alice"]
    )
    # Should not raise
  end

  def test_validate_event_invalid_type
    error = assert_raises(DcbEventStore::Validation::ValidationError) do
      DcbEventStore::Validation.validate_event(
        type: "123Invalid",
        data: {},
        tags: []
      )
    end
    assert_equal :type, error.field
  end

  def test_validate_event_invalid_data
    error = assert_raises(DcbEventStore::Validation::ValidationError) do
      DcbEventStore::Validation.validate_event(
        type: "ValidType",
        data: "not a hash",
        tags: []
      )
    end
    assert_equal :data, error.field
  end

  def test_validate_event_invalid_tags
    error = assert_raises(DcbEventStore::Validation::ValidationError) do
      DcbEventStore::Validation.validate_event(
        type: "ValidType",
        data: {},
        tags: ["tag,with,commas"]
      )
    end
    assert_equal :tags, error.field
  end

  # --- Global validation flag tests ---

  def test_global_validation_disabled_by_default
    # Save current state
    original = DcbEventStore.validate_events
    DcbEventStore.validate_events = nil

    # Should not raise with invalid type when validation is disabled
    e = DcbEventStore::Event.new(type: "123Invalid", validate: false)
    assert_equal "123Invalid", e.type

    # Restore
    DcbEventStore.validate_events = original
  end

  def test_global_validation_enabled
    # Save current state
    original = DcbEventStore.validate_events
    DcbEventStore.validate_events = true

    # Should raise with invalid type when validation is enabled
    error = assert_raises(DcbEventStore::Validation::ValidationError) do
      DcbEventStore::Event.new(type: "123Invalid")
    end
    assert_equal :type, error.field

    # Restore
    DcbEventStore.validate_events = original
  end

  def test_explicit_validate_parameter_overrides_global
    # Save current state
    original = DcbEventStore.validate_events
    DcbEventStore.validate_events = true

    # Should not raise even with invalid type when validate: false is explicit
    e = DcbEventStore::Event.new(type: "123Invalid", validate: false)
    assert_equal "123Invalid", e.type

    # Should raise with invalid type when validate: true is explicit (even if global is nil)
    DcbEventStore.validate_events = nil
    error = assert_raises(DcbEventStore::Validation::ValidationError) do
      DcbEventStore::Event.new(type: "123Invalid", validate: true)
    end
    assert_equal :type, error.field

    # Restore
    DcbEventStore.validate_events = original
  end
end
