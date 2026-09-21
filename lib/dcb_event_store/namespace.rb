require "zlib"

module DcbEventStore
  # Which set of tables a SQL store reads and writes, so several bounded
  # contexts can keep separate event logs in one database: their own
  # sequence, their own snapshots, their own subscribers.
  #
  # A namespace is a name that prefixes every database object the store
  # touches: the events table, SQLite's event_tags index, the
  # projection_snapshots table, and on PostgreSQL the NOTIFY channel and the
  # advisory-lock key space. The default namespace (nil) prefixes nothing,
  # so a store built without one keeps the original names.
  #
  # Names go straight into SQL identifiers, which cannot be bound as
  # parameters, hence the strict pattern: lowercase letters, digits and
  # underscores, starting with a letter. The length keeps every derived
  # identifier under PostgreSQL's 63-byte limit.
  #
  # Pure: a value, comparable by name.
  class Namespace
    NAME_PATTERN = /\A[a-z][a-z0-9_]*\z/
    # The longest identifier derived from a name is the PostgreSQL index
    # "idx_<name>_events_correlation_id" (26 characters around the name), and
    # PostgreSQL truncates identifiers past 63 bytes: 63 - 26.
    MAX_NAME_LENGTH = 37

    # Bits an advisory-lock key's namespace part is shifted by, leaving the
    # low 32 bits to the tag's crc32 (see PostgresStore::LockKeys).
    LOCK_OFFSET_SHIFT = 32
    # The namespace part is masked to 31 bits so the full key stays a
    # positive signed bigint.
    LOCK_OFFSET_MASK = 0x7FFF_FFFF

    attr_reader :name

    # The Namespace for +value+: a Namespace as it is, nil the default,
    # anything else its string form validated as a name.
    def self.wrap(value)
      value.is_a?(Namespace) ? value : new(value)
    end

    def initialize(name = nil)
      @name = validate(name)
      freeze
    end

    def default?
      @name.nil?
    end

    # +base+ prefixed with the name ("billing_events"), or +base+ itself in
    # the default namespace.
    def table(base)
      default? ? base : "#{@name}_#{base}"
    end

    def events_table
      table("events")
    end

    def event_tags_table
      table("event_tags")
    end

    def snapshots_table
      table("projection_snapshots")
    end

    # The PostgreSQL NOTIFY channel appends announce themselves on.
    def channel
      table("events_appended")
    end

    # Added to every advisory-lock key an append in this namespace takes, so
    # appends in different namespaces never serialize against each other. A
    # crc32 of the name in the high bits, leaving the tag's crc32 the low 32;
    # zero in the default namespace (the crc32 of the empty string), which
    # keeps its keys as they were.
    def lock_offset
      (Zlib.crc32(to_s) & LOCK_OFFSET_MASK) << LOCK_OFFSET_SHIFT
    end

    def ==(other)
      other.is_a?(Namespace) && other.name == @name
    end
    alias eql? ==

    def hash
      @name.hash
    end

    def to_s
      @name.to_s
    end

    def inspect
      default? ? "#<DcbEventStore::Namespace default>" : "#<DcbEventStore::Namespace #{@name}>"
    end

    def validate(name)
      return nil if name.nil?

      name = name.to_s
      unless NAME_PATTERN.match?(name)
        raise ArgumentError,
              "namespace #{name.inspect} must match #{NAME_PATTERN.inspect} (lowercase letters, digits, underscores)"
      end
      if name.length > MAX_NAME_LENGTH
        raise ArgumentError, "namespace #{name.inspect} is longer than #{MAX_NAME_LENGTH} characters"
      end

      name.freeze
    end
    private :validate

    # The namespace of a store built without one: no prefix anywhere.
    DEFAULT = new
  end
end
