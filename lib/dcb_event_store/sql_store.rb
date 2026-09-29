require "json"
require "time"

module DcbEventStore
  # Backend-neutral template for SQL-backed stores.
  #
  # Holds everything that does not depend on a particular SQL dialect or
  # driver: instrumentation, keyset-paginated reads, the append transaction
  # (locking, consistency check, per-event insert, wake-up notification) and
  # the subscribe catch-up/live loop.
  #
  # Subclasses supply the primitives below and set @row_mapper in their
  # constructor. Everything a subclass implements is a small, single-purpose
  # hook, so a new backend is a handful of methods rather than a second copy
  # of the append and read logic.
  class SqlStore
    include StoreInstrumentation

    BATCH_SIZE = 1000

    # The Namespace this store reads and writes (see Namespace): which event
    # log in the database is its own.
    attr_reader :namespace

    def initialize(upcaster: nil, subscribe_instrumentation: :event, namespace: nil)
      @upcaster = upcaster
      @subscribe_instrumentation = subscribe_instrumentation_mode(subscribe_instrumentation)
      @namespace = Namespace.wrap(namespace)
    end

    # The events matching +query+, oldest first, or newest first with
    # +backwards+; at most +limit+ of them (see ReadOptions). A lazy
    # Enumerator: the limit goes into the SQL, so limit: 1 fetches one row.
    def read(query, backwards: false, limit: nil)
      read_with(query, ReadOptions.new(backwards: backwards, limit: limit))
    end

    # #read from a position: forwards from +after+, or backwards from
    # +before+ (both exclusive).
    def read_from(query, after: nil, before: nil, backwards: false, limit: nil)
      read_with(query, ReadOptions.new(after: after, before: before, backwards: backwards, limit: limit))
    end

    # The sequence position of the last stored event, nil on an empty store.
    def last_position
      max_position
    end

    def append(events, condition = nil)
      events = Array(events)
      raise ArgumentError, "append needs at least one event" if events.empty?

      instrument_append(events, condition) do
        with_write_transaction do
          acquire_locks!(events, condition)

          sequenced = if condition
                        append_with_condition(events, condition)
                      else
                        append_without_condition(events)
                      end

          notify_position = sequenced.last&.sequence_position
          notify_appended(notify_position) if notify_position

          sequenced
        end
      end
    end

    # Writes +events+ as they were exported from a store: SequencedEvents (a
    # read from another store, or EventFile's decoded lines), keeping their
    # id, created_at and schema_version. sequence_position is not kept: the
    # events get fresh positions in the order given, so an import into a
    # store that already holds events appends after them. A nil created_at
    # takes the database's clock, a nil schema_version 1.
    #
    # One write transaction for the lot. Ids already stored are skipped, so
    # re-importing the same events is a no-op. No AppendCondition: an import
    # trusts its input, and takes the write lock every append waits on, so
    # none can interleave with it. Returns the SequencedEvents written.
    def import(events)
      events = Array(events)
      return [] if events.empty?

      instrument_import(events) { import_in_transaction(events) }
    end

    def subscribe(query, after: nil, &block)
      catch_up = after ? read_from(query, after: after) : read(query)
      last_pos = instrument_subscribe(catch_up, query, :catch_up, &block) || after

      listen
      loop do
        wait_for_append
        new_events = read_from(query, after: last_pos || 0)
        last_pos = instrument_subscribe(new_events, query, :live, &block) || last_pos
      end
    ensure
      unlisten
    end

    private

    def import_in_transaction(events)
      with_write_transaction do
        lock_for_import!

        imported = events.filter_map do |event|
          row = import_event(event)
          row && @row_mapper.to_imported_event(event, row)
        end

        notify_position = imported.last&.sequence_position
        notify_appended(notify_position) if notify_position

        imported
      end
    end

    def read_with(query, options)
      instrument_read(paginated_read(query, options), query, options)
    end

    # Reads the matching stream lazily, one BATCH_SIZE page at a time (or
    # less, as the limit runs out), using keyset pagination on
    # sequence_position in the read's direction, so a long stream never has
    # to fit in memory and a partially consumed enumerator stops fetching.
    def paginated_read(query, options)
      Enumerator.new do |yielder|
        loop do
          page = options.page_size(BATCH_SIZE)
          rows = fetch_batch(query, after: options.after, before: options.before, order: options.order, limit: page)
          rows.each { |row| yielder << @row_mapper.to_sequenced_event(row) }
          break if rows.size < page

          options = options.after_page(Integer(rows.last["sequence_position"]), rows.size)
          break unless options
        end
      end
    end

    # Default conditional append: check inside the write transaction, then
    # insert. Safe because the transaction plus #acquire_locks! serializes it
    # against competing appends. Backends that can do better (PostgreSQL
    # folds check and insert into one statement) override this.
    def append_with_condition(events, condition)
      matching = count_matching(condition.fail_if_events_match, condition.after)
      raise ConditionNotMet, "conflicting event(s)" if matching.positive?

      append_without_condition(events)
    end

    # Inserts the events one by one, skipping the ones whose event_id is
    # already stored (idempotent re-append) and returning a SequencedEvent
    # for each row that was actually written.
    def append_without_condition(events)
      events.filter_map do |event|
        row = insert_event(event)
        next nil if row.nil?

        @row_mapper.to_appended_event(event, row)
      end
    end

    # --- hooks a backend must implement ---

    # Runs the block in a transaction that serializes writers, committing on
    # success and rolling back on any exception.
    def with_write_transaction
      raise NotImplementedError, "#{self.class} must implement #with_write_transaction"
    end

    # Takes whatever locks the backend needs so the consistency check and the
    # inserts cannot interleave with a competing append: one that writes a tag
    # +condition+ names, or whose condition names a tag +events+ carry. May be
    # a no-op when the write transaction already serializes globally.
    def acquire_locks!(events, condition)
      raise NotImplementedError, "#{self.class} must implement #acquire_locks!"
    end

    # Number of stored events matching +query+ after position +after+.
    def count_matching(query, after)
      raise NotImplementedError, "#{self.class} must implement #count_matching"
    end

    # Inserts one event, returning its row (at least sequence_position and
    # created_at) or nil when an event with the same id already exists.
    def insert_event(event)
      raise NotImplementedError, "#{self.class} must implement #insert_event"
    end

    # Takes the lock that keeps every append out while an import runs. May
    # be a no-op when the write transaction already serializes globally.
    def lock_for_import!
      raise NotImplementedError, "#{self.class} must implement #lock_for_import!"
    end

    # Inserts one exported event with its created_at and schema_version,
    # returning its row like #insert_event, or nil when its id is stored.
    def import_event(event)
      raise NotImplementedError, "#{self.class} must implement #import_event"
    end

    # One page of at most +limit+ matching rows as string-keyed hashes,
    # ordered by sequence position (+order+ :asc or :desc), between +after+
    # and +before+ (either nil = unbounded on that side). The arguments are
    # SqlBuilder#read_sql's.
    def fetch_batch(query, after:, before:, order:, limit:)
      raise NotImplementedError, "#{self.class} must implement #fetch_batch"
    end

    # The highest sequence_position in the events table, nil when empty.
    def max_position
      raise NotImplementedError, "#{self.class} must implement #max_position"
    end

    # Announces that events up to +position+ were committed, so subscribers
    # blocked in #wait_for_append wake up.
    def notify_appended(position)
      raise NotImplementedError, "#{self.class} must implement #notify_appended"
    end

    # Starts listening for append notifications for this subscription.
    def listen
      raise NotImplementedError, "#{self.class} must implement #listen"
    end

    # Stops listening. Called from an ensure block, so it must not raise.
    def unlisten
      raise NotImplementedError, "#{self.class} must implement #unlisten"
    end

    # Blocks until there may be new events to read.
    def wait_for_append
      raise NotImplementedError, "#{self.class} must implement #wait_for_append"
    end
  end
end

# Loaded after the class body on purpose: these files reopen `class SqlStore`,
# which while this file is itself being autoloaded would re-enter the autoload
# rather than reopen the class defined above.
require_relative "sql_store/sql_builder"
require_relative "sql_store/row_mapper"
require_relative "sql_store/timestamp"
