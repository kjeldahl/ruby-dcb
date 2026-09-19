require_relative "../test_helper"
require "dcb_event_store/sql_store"

class TestTimestamp < Minitest::Test
  cover "DcbEventStore::SqlStore::Timestamp*"

  def parse(text)
    DcbEventStore::SqlStore::Timestamp.parse(text)
  end

  # Every timestamp the parser is meant to read has to come back exactly as
  # Time.parse reads it -- same instant, same sub-second digits and same zone,
  # since a UTC Time and a +0000 Time are equal but do not print alike.
  def assert_parses_like_time_parse(text)
    expected = Time.parse(text)
    actual = parse(text)

    assert_equal expected, actual, "instant differs for #{text.inspect}"
    assert_equal expected.nsec, actual.nsec, "sub-second differs for #{text.inspect}"
    assert_equal expected.utc_offset, actual.utc_offset, "offset differs for #{text.inspect}"
    assert_equal expected.utc?, actual.utc?, "utc? differs for #{text.inspect}"
    assert_equal expected.inspect, actual.inspect
    actual
  end

  # --- the formats the backends emit ---

  def test_postgres_timestamptz
    # PostgreSQL renders TIMESTAMPTZ with a space, microseconds and a
    # two-digit zone.
    event = assert_parses_like_time_parse("2026-06-13 22:00:00.123456+00")

    assert_equal 2026, event.year
    assert_equal 6, event.month
    assert_equal 13, event.day
    assert_equal 22, event.hour
    assert_equal 0, event.min
    assert_equal 0, event.sec
    assert_equal 123_456, event.usec
    assert_equal 0, event.utc_offset
  end

  def test_sqlite_column_default
    # SQLite's strftime('%Y-%m-%dT%H:%M:%fZ') default: T separator,
    # milliseconds, trailing Z.
    event = assert_parses_like_time_parse("2026-06-13T22:00:00.123Z")

    assert_equal 123_000, event.usec
    assert_predicate event, :utc?
  end

  def test_lowercase_zone_marker
    assert_parses_like_time_parse("2026-06-13t22:00:00.123z")
  end

  # --- every field is read from its own position ---

  def test_reads_each_field
    event = assert_parses_like_time_parse("1987-12-31 23:59:58.000001+00")

    assert_equal 1987, event.year
    assert_equal 12, event.month
    assert_equal 31, event.day
    assert_equal 23, event.hour
    assert_equal 59, event.min
    assert_equal 58, event.sec
    assert_equal 1, event.usec
  end

  def test_leading_zeros_everywhere
    event = assert_parses_like_time_parse("0001-01-01T00:00:00.000000Z")

    assert_equal 1, event.year
    assert_equal 1, event.month
    assert_equal 1, event.day
  end

  # --- fractions of every length PostgreSQL trims to ---

  def test_fraction_lengths
    # PostgreSQL drops trailing zeros, so a stored .100000 comes back as .1.
    {
      "2026-06-13 22:00:00.1+00" => 100_000,
      "2026-06-13 22:00:00.12+00" => 120_000,
      "2026-06-13 22:00:00.123+00" => 123_000,
      "2026-06-13 22:00:00.1234+00" => 123_400,
      "2026-06-13 22:00:00.12345+00" => 123_450,
      "2026-06-13 22:00:00.123456+00" => 123_456
    }.each do |text, usec|
      assert_equal usec, assert_parses_like_time_parse(text).usec
    end
  end

  def test_no_fraction
    assert_equal 0, assert_parses_like_time_parse("2026-06-13 22:00:00+00").usec
  end

  def test_no_fraction_with_z
    assert_equal 0, assert_parses_like_time_parse("2026-06-13T22:00:00Z").usec
  end

  # --- zones ---

  def test_hours_only_offset
    assert_equal 7200, assert_parses_like_time_parse("2026-06-13 22:00:00.123456+02").utc_offset
  end

  def test_negative_hours_only_offset
    assert_equal(-18_000, assert_parses_like_time_parse("2026-06-13 22:00:00-05").utc_offset)
  end

  def test_colon_separated_offset
    assert_equal 19_800, assert_parses_like_time_parse("2026-06-13 22:00:00.123456+05:30").utc_offset
  end

  def test_compact_offset
    assert_equal 19_800, assert_parses_like_time_parse("2026-06-13T22:00:00.123456+0530").utc_offset
  end

  def test_negative_offset_with_minutes
    assert_equal(-34_200, assert_parses_like_time_parse("2026-06-13T22:00:00.5-09:30").utc_offset)
  end

  def test_offset_shifts_the_instant
    # 22:00 at +02:00 is 20:00 UTC, not 22:00 UTC.
    assert_equal Time.utc(2026, 6, 13, 20, 0, 0), parse("2026-06-13 22:00:00+02")
  end

  def test_zero_offset_is_not_utc
    # Time.parse gives "+00" a fixed zero offset rather than the UTC flag, and
    # the two print differently.
    refute_predicate parse("2026-06-13 22:00:00+00"), :utc?
    assert_predicate parse("2026-06-13T22:00:00Z"), :utc?
  end

  # --- anything else falls through to Time.parse ---

  def test_falls_back_for_zoneless_timestamp
    # Without a zone Time.parse reads local time; the fast path declines.
    assert_parses_like_time_parse("2026-06-13 22:00:00")
  end

  def test_falls_back_for_sub_microsecond_digits
    assert_parses_like_time_parse("2026-06-13 22:00:00.1234567+00")
    assert_parses_like_time_parse("2026-06-13T22:00:00.123456789Z")
  end

  def test_falls_back_for_year_outside_four_digits
    assert_parses_like_time_parse("10000-01-01 00:00:00+00")
  end

  def test_falls_back_for_date_only
    assert_parses_like_time_parse("2026-06-13")
  end

  def test_falls_back_for_rfc_2822
    assert_parses_like_time_parse("Fri, 13 Jun 2026 22:00:00 +0000")
  end

  def test_falls_back_for_offset_with_seconds
    assert_parses_like_time_parse("2026-06-13 22:00:00+00:00:30")
  end

  def test_raises_like_time_parse_on_junk
    ["", "nope", "infinity", "-infinity", "2026-13-99 00:00:00+00"].each do |text|
      assert_raises(ArgumentError, "expected #{text.inspect} to raise") { parse(text) }
    end
  end

  def test_raises_on_non_string
    assert_raises(TypeError) { parse(nil) }
  end

  # --- the fast path is actually taken ---

  def test_recognized_shapes_never_reach_time_parse
    # The point of the class: Time.parse reads these correctly too, it just
    # costs several times as much, so a shape that stops being recognised is
    # a silent performance regression rather than a wrong answer.
    expected = Time.utc(2026, 6, 13, 22, 0, 0, 123_000)

    Time.stub(:parse, ->(text) { flunk("Time.parse called for #{text.inspect}") }) do
      assert_equal expected, parse("2026-06-13T22:00:00.123Z")
      assert_equal expected, parse("2026-06-13 22:00:00.123+00")
      assert_equal expected, parse("2026-06-14 03:30:00.123+05:30")
      assert_equal expected, parse("2026-06-13T22:00:00.123+0000")
    end
  end

  # --- the fast path and Time.parse agree across the whole range ---

  def test_agrees_with_time_parse_over_many_timestamps
    random = Random.new(20_260_613)
    500.times do
      time = Time.at(random.rand(0..4_000_000_000), random.rand(0..999_999), :usec)
      [
        time.utc.strftime("%Y-%m-%d %H:%M:%S.%6N+00"),
        time.utc.strftime("%Y-%m-%dT%H:%M:%S.%3NZ"),
        time.getlocal("+05:45").strftime("%Y-%m-%d %H:%M:%S.%6N%:z"),
        time.getlocal("-03:00").strftime("%Y-%m-%dT%H:%M:%S%z")
      ].each { |text| assert_parses_like_time_parse(text) }
    end
  end
end
