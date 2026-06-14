module DcbEventStore
  # Encodes/decodes PostgreSQL text array literals (e.g. {a,b} or {"a","b,c"})
  # to and from Ruby arrays of strings.
  #
  # Delegates to PG's text array codec, which implements the full array grammar
  # (quoting, backslash escaping, embedded commas, braces, whitespace, empty
  # strings). The codec objects perform no I/O, so this class needs the `pg`
  # gem loaded but never a live connection.
  #
  # PG is referenced lazily so requiring the gem never touches PG at load time.
  #
  # Examples:
  #   PgArrayCodec.new.parse('{a,b}')      => ["a", "b"]
  #   PgArrayCodec.new.parse('{"a\"b"}')   => ['a"b']
  #   PgArrayCodec.new.parse(nil)          => []
  #   PgArrayCodec.new.encode(["a", "b"])  => '{a,b}'
  #   PgArrayCodec.new.encode(['a"b'])     => '{"a\"b"}'
  #   PgArrayCodec.new.encode([])          => '{}'
  class PgArrayCodec
    # Parses a PostgreSQL text array literal into a Ruby array of strings.
    # Returns [] for nil.
    def parse(str)
      return [] if str.nil?

      decoder.decode(str)
    end

    # Converts a Ruby array into a PostgreSQL text array literal, coercing each
    # element to a string and escaping special characters so it round-trips
    # through a text[] column or bind parameter.
    def encode(arr)
      encoder.encode(arr.map(&:to_s))
    end

    private

    def decoder
      @decoder ||= PG::TextDecoder::Array.new
    end

    def encoder
      @encoder ||= PG::TextEncoder::Array.new
    end
  end
end
