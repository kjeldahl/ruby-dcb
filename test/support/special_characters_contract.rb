# Shared behavioral contract for special characters and empty values in tags,
# event types and data. Exercises the full append/read round trip, so every
# backend must encode and decode them without loss and must still match
# containment queries when a tag needs quoting in the backend's own tag
# encoding.
#
# Including classes must set @store in setup.
module SpecialCharactersContract
  # Tags that are metacharacters in at least one backend's tag encoding
  # (commas, quotes, braces, backslashes, whitespace), plus an empty string
  # and Unicode.
  SPECIAL_TAGS = [
    'tag"with"quotes',
    "tag,with,commas",
    "tag{with}braces",
    'tag\\with\\backslash',
    "tag with spaces",
    "tag_with_émojis_🎉",
    ""
  ].freeze

  # --- tag special characters ---

  def test_append_then_read_preserves_special_char_tags
    @store.append([DcbEventStore::Event.new(type: "A", tags: SPECIAL_TAGS)])

    event = @store.read(DcbEventStore::Query.all).first
    assert_equal SPECIAL_TAGS, event.tags
  end

  def test_containment_query_matches_special_char_tag
    @store.append([DcbEventStore::Event.new(type: "A", tags: ["course:c1", "tag,with,commas"])])
    @store.append([DcbEventStore::Event.new(type: "A", tags: ["course:c2"])])

    events = read_by_tag("tag,with,commas", event_types: ["A"])

    assert_equal 1, events.size
    assert_includes events[0].tags, "tag,with,commas"
  end

  def test_containment_query_does_not_overmatch_on_quoted_tag
    @store.append([DcbEventStore::Event.new(type: "A", tags: ['tag"with"quotes'])])

    assert_empty read_by_tag("tag", event_types: ["A"])
  end

  def test_tags_with_colons
    assert_tag_round_trips(["order:123", "customer:alice"], "order:123")
  end

  def test_tags_with_hyphens
    assert_tag_round_trips(%w[order-123 high-priority], "order-123")
  end

  def test_tags_with_underscores
    assert_tag_round_trips(%w[order_123 internal_use], "order_123")
  end

  def test_tags_with_dots
    assert_tag_round_trips(["order.123", "v1.0"], "order.123")
  end

  def test_tags_with_slashes
    assert_tag_round_trips(["tenant/acme", "region/us-east"], "tenant/acme")
  end

  def test_tags_with_unicode
    assert_tag_round_trips(["customer:alice", "region:北京"], "region:北京")
  end

  def test_tags_with_emoji
    assert_tag_round_trips(["priority:🔥", "status:✅"], "priority:🔥")
  end

  def test_tags_with_spaces
    assert_tag_round_trips(["customer name:alice", "order id:123"], "customer name:alice")
  end

  # --- event type special characters ---

  def test_event_type_with_colons
    assert_type_round_trips("Order:Created")
  end

  def test_event_type_with_hyphens
    assert_type_round_trips("Order-Created")
  end

  def test_event_type_with_underscores
    assert_type_round_trips("Order_Created")
  end

  # --- data special characters ---

  def test_data_with_unicode
    data = {customer_name: "Alice", notes: "客户订单"}
    assert_equal 1, @store.append([event_with(data: data)]).size

    read_events = @store.read(DcbEventStore::Query.all).to_a
    assert_equal "客户订单", read_events[0].data[:notes]
  end

  def test_data_with_emoji
    data = {status: "✅", priority: "🔥"}
    assert_equal 1, @store.append([event_with(data: data)]).size

    read_events = @store.read(DcbEventStore::Query.all).to_a
    assert_equal "✅", read_events[0].data[:status]
    assert_equal "🔥", read_events[0].data[:priority]
  end

  def test_data_with_special_json_characters
    data = {text: "Line 1\nLine 2", tab: "Col1\tCol2", quote: 'He said "hello"'}
    assert_equal 1, @store.append([event_with(data: data)]).size

    read_events = @store.read(DcbEventStore::Query.all).to_a
    assert_equal "Line 1\nLine 2", read_events[0].data[:text]
    assert_equal "Col1\tCol2", read_events[0].data[:tab]
    assert_equal 'He said "hello"', read_events[0].data[:quote]
  end

  def test_data_with_nested_structure
    data = {
      order: {
        id: "123",
        items: [
          {name: "Item 1", price: 10.99},
          {name: "Item 2", price: 20.50}
        ],
        metadata: {
          created_at: Time.now.iso8601,
          updated_at: Time.now.iso8601
        }
      }
    }
    assert_equal 1, @store.append([event_with(data: data)]).size

    read_events = @store.read(DcbEventStore::Query.all).to_a
    assert_equal "Item 1", read_events[0].data[:order][:items][0][:name]
    assert_equal 10.99, read_events[0].data[:order][:items][0][:price]
  end

  # --- empty and nil values ---

  def test_empty_tags
    assert_equal 1, @store.append([event_with(data: {id: "123"}, tags: [])]).size

    read_events = @store.read(DcbEventStore::Query.all).to_a
    assert_equal [], read_events[0].tags
  end

  def test_empty_data
    assert_equal 1, @store.append([event_with(data: {})]).size

    read_events = @store.read(DcbEventStore::Query.all).to_a
    assert_equal({}, read_events[0].data)
  end

  def test_nil_data_roundtrips_as_nil
    assert_equal 1, @store.append([event_with(data: nil)]).size

    read_events = @store.read(DcbEventStore::Query.all).to_a
    # nil data is serialized as JSON null and read back as nil.
    assert_nil read_events[0].data
  end

  private

  def event_with(data: {}, tags: ["order:123"])
    DcbEventStore::Event.new(type: "OrderCreated", data: data, tags: tags)
  end

  def read_by_tag(tag, event_types: [])
    query = DcbEventStore::Query.new([
                                       DcbEventStore::QueryItem.new(event_types: event_types, tags: [tag])
                                     ])
    @store.read(query).to_a
  end

  def assert_tag_round_trips(tags, queried_tag)
    assert_equal 1, @store.append([event_with(tags: tags)]).size

    read_events = read_by_tag(queried_tag)
    assert_equal 1, read_events.size
    assert_equal "OrderCreated", read_events[0].type
    assert_equal tags, read_events[0].tags
  end

  def assert_type_round_trips(type)
    event = DcbEventStore::Event.new(type: type, data: {id: "123"}, tags: ["order:123"])
    assert_equal 1, @store.append([event]).size

    query = DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: [type])])
    read_events = @store.read(query).to_a
    assert_equal 1, read_events.size
    assert_equal type, read_events[0].type
  end
end
