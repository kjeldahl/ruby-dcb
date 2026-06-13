require_relative "../test_helper"
require "pg"

class TestRowMapper < Minitest::Test
  cover "DcbEventStore::Store::RowMapper*"

  def setup
    @codec = DcbEventStore::PgArrayCodec.new
  end

  def mapper(upcaster: nil)
    DcbEventStore::Store::RowMapper.new(@codec, upcaster)
  end

  def row(overrides = {})
    {
      "sequence_position" => "42",
      "type" => "OrderPlaced",
      "data" => '{"amount":10}',
      "tags" => "{t1,t2}",
      "created_at" => "2026-06-13 22:00:00+00",
      "event_id" => "evt-1",
      "causation_id" => "cause-1",
      "correlation_id" => "corr-1",
      "schema_version" => "3"
    }.merge(overrides)
  end

  # --- to_sequenced_event ---

  def test_to_sequenced_event_maps_all_columns
    event = mapper.to_sequenced_event(row)

    assert_equal 42, event.sequence_position
    assert_equal "OrderPlaced", event.type
    assert_equal({ amount: 10 }, event.data)
    assert_equal %w[t1 t2], event.tags
    assert_equal Time.parse("2026-06-13 22:00:00+00"), event.created_at
    assert_equal "evt-1", event.id
    assert_equal "cause-1", event.causation_id
    assert_equal "corr-1", event.correlation_id
    assert_equal 3, event.schema_version
  end

  def test_to_sequenced_event_parses_json_with_symbol_keys
    event = mapper.to_sequenced_event(row("data" => '{"nested":{"a":1}}'))
    assert_equal({ nested: { a: 1 } }, event.data)
  end

  def test_to_sequenced_event_applies_upcaster
    upcaster = Object.new
    def upcaster.upcast(type, data, version)
      [data.merge(upcasted: type), version + 1]
    end

    event = mapper(upcaster: upcaster).to_sequenced_event(row)

    assert_equal({ amount: 10, upcasted: "OrderPlaced" }, event.data)
    assert_equal 4, event.schema_version
  end

  # --- to_appended_event ---

  def test_to_appended_event_takes_payload_from_event
    src = DcbEventStore::Event.new(type: "A", data: { n: 1 }, tags: ["t1"],
                                   id: "id-1", causation_id: "c-1", correlation_id: "r-1")
    appended = mapper.to_appended_event(src, row)

    assert_equal 42, appended.sequence_position
    assert_equal Time.parse("2026-06-13 22:00:00+00"), appended.created_at
    assert_equal "A", appended.type
    assert_equal({ n: 1 }, appended.data)
    assert_equal ["t1"], appended.tags
    assert_equal "id-1", appended.id
    assert_equal "c-1", appended.causation_id
    assert_equal "r-1", appended.correlation_id
    assert_equal 1, appended.schema_version
  end
end
