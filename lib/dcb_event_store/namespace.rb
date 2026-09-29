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
  # identifier under PostgreSQL's 63-byte limit, and "sqlite" is refused as
  # a name (or its "sqlite_" prefix) because SQLite reserves table names
  # starting with "sqlite_": one rule on every backend, so a name valid
  # here is valid everywhere.
  #
  # Pure: a value, comparable by name.
  class Namespace
    NAME_PATTERN = /\A[a-z][a-z0-9_]*\z/
    # The longest identifier derived from a name is the sequence PostgreSQL
    # names for the events table's BIGSERIAL column,
    # "<name>_events_sequence_position_seq" (29 characters around the name),
    # and PostgreSQL truncates identifiers past 63 bytes: 63 - 29. (The
    # longest index, "idx_<name>_events_correlation_id", is 26 around it.)
    MAX_NAME_LENGTH = 34
    # Names SQLite would refuse as a table prefix: "sqlite_events" and
    # "sqlite_x_events" both begin with the reserved "sqlite_".
    RESERVED_PATTERN = /\Asqlite(_|\z)/

    # Bits an advisory-lock key's namespace part is shifted by, leaving the
    # low 32 bits to the tag's crc32 (see PostgresStore::LockKeys).
    LOCK_OFFSET_SHIFT = 32
    # The namespace part is masked to 31 bits so the full key stays a
    # positive signed bigint.
    LOCK_OFFSET_MASK = 0x7FFF_FFFF

    # Namespaces built so far by lock offset, to notice two names sharing
    # one (see #lock_offset).
    OFFSET_OWNERS = Hash.new { |hash, offset| hash[offset] = [] }
    OFFSET_OWNERS_LOCK = Mutex.new
    private_constant :OFFSET_OWNERS, :OFFSET_OWNERS_LOCK

    attr_reader :name, :lock_offset

    # The Namespace for +value+: a Namespace as it is, nil the default,
    # anything else its string form validated as a name.
    def self.wrap(value)
      value.is_a?(Namespace) ? value : new(value)
    end

    def initialize(name = nil)
      @name = validate(name)
      @lock_offset = compute_lock_offset
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

    # #lock_offset is added to every advisory-lock key an append in this
    # namespace takes, so appends in different namespaces do not serialize
    # against each other. A crc32 of the name in the high bits, leaving the
    # tag's crc32 the low 32; zero is the default namespace's alone (keeping
    # its keys as they were), so a name that hashes to zero takes 1.
    #
    # 31 bits do not tell every name apart: two names may share an offset,
    # which only makes their appends serialize against each other (never a
    # missed conflict). The first time a name lands on an offset another
    # already holds, a "namespace_collision.dcb" event names both (published
    # through DcbEventStore.instrumentation, so it reaches whatever logging
    # or metrics the application subscribed).

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

    def compute_lock_offset
      return 0 if default?

      slot = Zlib.crc32(@name) & LOCK_OFFSET_MASK
      slot = 1 if slot.zero?
      offset = slot << LOCK_OFFSET_SHIFT
      warn_on_shared_offset(offset)
      offset
    end
    private :compute_lock_offset

    def warn_on_shared_offset(offset)
      others = OFFSET_OWNERS_LOCK.synchronize do
        owners = OFFSET_OWNERS[offset]
        if owners.include?(@name)
          []
        else
          owners.dup.tap { owners << @name }
        end
      end
      return if others.empty?

      payload = { namespace: @name, shares_with: others, lock_offset: offset }
      DcbEventStore.instrumentation.instrument(StoreInstrumentation::NAMESPACE_COLLISION_EVENT, payload, &:itself)
    end
    private :warn_on_shared_offset

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

      if RESERVED_PATTERN.match?(name)
        raise ArgumentError, "namespace #{name.inspect} is reserved: SQLite reserves table names starting with sqlite_"
      end

      name.freeze
    end
    private :validate

    # The namespace of a store built without one: no prefix anywhere.
    DEFAULT = new
  end
end
