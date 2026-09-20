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

    def initialize(upcaster: nil, subscribe_instrumentation: :event)
      @upcaster = upcaster
      @subscribe_instrumentation = subscribe_instrumentation_mode(subscribe_instrumentation)
    end

    def read(query)
      instrument_read(paginated_read(query, after: nil), query, nil)
    end

    def read_from(query, after:)
      instrument_read(paginated_read(query, after: after), query, after)
    end

    # The sequence position of the last stored event, nil on an empty store.
    def last_position
      max_position
    end

    def append(events, condition = nil)
      events = Array(events)
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

    # Reads the matching stream lazily, one BATCH_SIZE page at a time, using
    # keyset pagination on sequence_position so a long stream never has to fit
    # in memory and a partially consumed enumerator stops fetching.
    def paginated_read(query, after:)
      Enumerator.new do |yielder|
        cursor = after
        loop do
          rows = fetch_batch(query, after: cursor, limit: BATCH_SIZE)
          break if rows.empty?

          rows.each do |row|
            cursor = row["sequence_position"].to_i
            yielder << @row_mapper.to_sequenced_event(row)
          end
          break if rows.size < BATCH_SIZE
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

    # One page of matching rows as string-keyed hashes, ordered by ascending
    # sequence position, starting after +after+ (nil = from the beginning).
    def fetch_batch(query, after:, limit:)
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
