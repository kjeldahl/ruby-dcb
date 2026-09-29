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

    # Appends +events+, guarded by +condition+ when given, and returns their
    # SequencedEvents.
    #
    # Idempotent by event id: when every id is already stored, the append is
    # taken for a retry of one that went through (its response lost) and
    # returns the stored events, without checking +condition+ -- which the
    # retry's own events would otherwise fail. Ids are all that is compared.
    # Some ids stored and some not raises DuplicateEvent and writes nothing.
    def append(events, condition = nil)
      events = Array(events)
      raise ArgumentError, "append needs at least one event" if events.empty?

      instrument_append(events, condition) do |payload|
        with_write_transaction do
          acquire_locks!(events, condition)

          sequenced = if condition
                        append_with_condition(events, condition)
                      else
                        append_without_condition(events)
                      end
          if sequenced.empty?
            stored = replay(events)
            payload[:replayed] = true
            next stored
          end

          reject_partial_duplicates!(events, sequenced)
          notify_appended(sequenced.last.sequence_position)
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

    # Delivers every event matching +query+ (after position +after+), then
    # blocks and delivers new ones as they are committed. How far it got is
    # a cursor only the backend reads: a position where events commit in
    # position order, more on a backend where they need not (see
    # PostgresStore#subscription_cursor).
    #
    # Listens before catching up: an append committed between the catch-up
    # read and the start of listening would otherwise wake nobody.
    def subscribe(query, after: nil, &block)
      listen
      cursor = subscription_cursor(after)
      cursor = deliver_new(query, cursor, :catch_up, &block)

      loop do
        wait_for_append
        cursor = deliver_new(query, cursor, :live, &block)
      end
    ensure
      unlisten
    end

    # Answers each SettleCheck: whether a snapshot of its query's events may
    # be written at its +through+. Default: a count alone, which is enough
    # where positions commit in order, since an append still in flight then
    # holds positions past every committed one. PostgresStore overrides it.
    def settled(checks)
      checks.map { |check| count_between(check.query, check.after, check.through) == check.count }
    end

    # #settled for one check.
    def settled?(query, after:, through:, count:)
      settled([SettleCheck.new(query: query, after: after, through: through, count: count)]).first
    end

    private

    # The cursor a subscription starts from. Here a position: events commit
    # in position order (a single writer), so none can later appear below
    # the last one delivered.
    def subscription_cursor(after)
      after
    end

    # Delivers what matches +query+ past +cursor+ and returns the cursor
    # moved past it.
    def deliver_new(query, cursor, phase, &)
      events = phase == :live || cursor ? read_from(query, after: cursor || 0) : read(query)
      instrument_subscribe(events, query, phase, &) || cursor
    end

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
    #
    # A failed condition writes nothing and returns no events, like an
    # append whose ids are all stored: #replay tells the two apart, and so
    # only runs its lookup when nothing was written.
    def append_with_condition(events, condition)
      matching = count_matching(condition.fail_if_events_match, condition.after)
      return [] if matching.positive?

      append_without_condition(events)
    end

    # An append that wrote nothing: either every id is stored (a retry,
    # answered with the stored events) or the condition failed. Checked in
    # that order, so a retry never trips over its own events.
    def replay(events)
      ids = events.map(&:id).uniq
      stored = fetch_by_ids(ids)
      raise ConditionNotMet, "conflicting event(s)" if stored.empty?

      stored_ids = stored.map { |row| row["event_id"] }
      raise DuplicateEvent, stored_ids if stored_ids.size < ids.size

      stored.map { |row| @row_mapper.to_sequenced_event(row) }
    end

    # An append that wrote some events but skipped others as stored. Raising
    # rolls the written ones back.
    def reject_partial_duplicates!(events, sequenced)
      skipped = events.map(&:id).uniq - sequenced.map(&:id)
      raise DuplicateEvent, skipped unless skipped.empty?
    end

    # Inserts the events one by one, skipping the ones whose event_id is
    # already stored and returning a SequencedEvent for each row that was
    # actually written.
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

    # Number of stored events matching +query+ in (+after+, +through+],
    # +after+ nil meaning from the start.
    def count_between(query, after, through)
      raise NotImplementedError, "#{self.class} must implement #count_between"
    end

    # Inserts one event, returning its row (at least sequence_position and
    # created_at) or nil when an event with the same id already exists.
    def insert_event(event)
      raise NotImplementedError, "#{self.class} must implement #insert_event"
    end

    # The stored rows (as #fetch_batch returns them) whose event_id is one of
    # +ids+, ordered by ascending sequence position.
    def fetch_by_ids(ids)
      raise NotImplementedError, "#{self.class} must implement #fetch_by_ids"
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
