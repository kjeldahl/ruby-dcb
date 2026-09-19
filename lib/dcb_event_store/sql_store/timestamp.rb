require "time"

module DcbEventStore
  class SqlStore
    # Parses the +created_at+ text the SQL backends hand back into a Time.
    #
    # Both backends emit one fixed shape -- PostgreSQL renders TIMESTAMPTZ as
    # "2026-06-13 22:00:00.123456+00" and SQLite's column default as
    # "2026-06-13T22:00:00.123Z" -- so the general-purpose Time.parse, which
    # works its way through dozens of formats before it recognises either, is
    # by a wide margin the most expensive step of decoding a row: ~11us of the
    # ~15us it took to build one SequencedEvent. Reading the digits straight
    # out of their known positions costs ~2-3us instead, cutting the cost of
    # a decoded row by half -- which is worth the lines when a projection
    # replays hundreds of thousands of events.
    #
    # Only that shape is read here; everything else -- a zoneless timestamp, a
    # year outside four digits, sub-microsecond digits, "infinity", an RFC 2822
    # date -- falls through to Time.parse, so the fast path narrows what the
    # store accepts by nothing at all. The Times it returns match Time.parse's
    # down to the zone: UTC for a trailing "Z", a fixed offset for "+HH",
    # "+HHMM" or "+HH:MM".
    #
    # Pure: no connection, no I/O.
    module Timestamp
      # The shape #parse reads directly. Matching it guarantees a digit at
      # every position the code below picks apart, which is what lets that
      # code index the string without checking anything, and failing it is
      # what routes the odd format to Time.parse. A zone is required: without
      # one Time.parse reads the text as local time, and reproducing that
      # (with its DST ambiguities) is not worth the few microseconds.
      RECOGNIZED = /\A\d{4}-\d\d-\d\d[ T]\d\d:\d\d:\d\d(?:\.\d{1,6})?(?:[Zz]|[+-]\d\d(?::?\d\d)?)\z/

      # Byte offset just past the seconds, where the optional fraction starts
      # and, when there is none, the zone.
      FRACTION = 19

      # Multiplier turning a fraction into whole microseconds, keyed by how
      # many bytes it spans including its dot: 0 for a timestamp carrying no
      # fraction at all, then 2 (".1") through 7 (".123456"). PostgreSQL trims
      # trailing zeros off what it stored, so every length in between turns up.
      MICROSECOND_SCALE = {
        0 => 0, 2 => 100_000, 3 => 10_000, 4 => 1_000, 5 => 100, 6 => 10, 7 => 1
      }.freeze

      # The zone suffix starts at the first of these bytes past the seconds:
      # whatever lies between is the fraction, which is digits alone.
      ZONE_MARKER = /[Zz+-]/

      DASH = "-".ord
      COLON = ":".ord
      ZERO = "0".ord
      # Zone markers standing for UTC itself rather than an offset.
      ZONE_UTC = ["Z".ord, "z".ord].freeze

      # The Time +text+ denotes: read straight from its digits when it carries
      # the shape RECOGNIZED describes, and by Time.parse when it does not.
      def self.parse(text)
        return Time.parse(text) unless RECOGNIZED.match?(text)

        zone = zone_start(text)

        # Read from the fixed positions RECOGNIZED pins down. The year is
        # spelled out rather than handed to the variable-length #digits: it is
        # the only field wider than two bytes, and at this scale the loop
        # costs more than the four reads it saves --
        #
        #   0    5  8  11 14 17  19
        #   YYYY-MM-DD HH:MM:SS.ffffff+HH:MM
        utc = Time.utc(
          ((text.getbyte(0) - ZERO) * 1000) + ((text.getbyte(1) - ZERO) * 100) +
            ((text.getbyte(2) - ZERO) * 10) + (text.getbyte(3) - ZERO),
          two_digits(text, 5), two_digits(text, 8), two_digits(text, 11),
          two_digits(text, 14), two_digits(text, 17),
          microseconds(text, zone)
        )

        return utc if ZONE_UTC.include?(text.getbyte(zone))

        offset = utc_offset(text, zone)
        (utc - offset).localtime(offset)
      end

      # Byte offset of the zone suffix: right after the seconds, or after the
      # fraction when the text carries one. RECOGNIZED having matched, the
      # search cannot come up empty -- and it also leaves only ASCII, so the
      # character offset #index counts in is the byte offset #getbyte wants.
      def self.zone_start(text)
        text.index(ZONE_MARKER, FRACTION)
      end

      # The fractional seconds as whole microseconds, where +zone+ is the byte
      # the fraction stops at. A timestamp with no fraction needs no special
      # case: its span is empty, so #digits reads nothing and the scale is 0.
      def self.microseconds(text, zone)
        span = zone - FRACTION
        digits(text, FRACTION + 1, span - 1) * MICROSECOND_SCALE.fetch(span)
      end

      # Seconds east of UTC for the "+HH", "+HHMM" or "+HH:MM" suffix starting
      # at byte +at+, negative for a "-" sign.
      def self.utc_offset(text, at)
        minutes = at + 3
        minutes += 1 if text.getbyte(minutes) == COLON
        seconds = two_digits(text, at + 1) * 3600
        seconds += two_digits(text, minutes) * 60 if text.getbyte(minutes)
        text.getbyte(at) == DASH ? -seconds : seconds
      end

      # The two-digit number starting at byte +at+: every field of the date
      # and time but the year, and both halves of the zone offset.
      def self.two_digits(text, at)
        ((text.getbyte(at) - ZERO) * 10) + (text.getbyte(at + 1) - ZERO)
      end

      # The +length+-digit number starting at byte +at+, for the fraction --
      # the one field whose length is not known up front. A length of zero or
      # less reads nothing and comes back 0.
      def self.digits(text, at, length)
        value = 0
        last = at + length
        while at < last
          value = (value * 10) + (text.getbyte(at) - ZERO)
          at += 1
        end
        value
      end

      private_class_method :zone_start, :microseconds, :utc_offset, :two_digits,
                           :digits
    end
  end
end
