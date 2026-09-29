require "json"

module DcbEventStore
  # In-memory drop-in replacement for PostgresStore, intended for fast tests
  # (e.g. mutation testing) where a live PostgreSQL server is too slow.
  #
  # Not thread-safe: it is meant for single-threaded test runs only.
  # Unlike PostgresStore, #subscribe does not block waiting for
  # notifications; it catches up on existing events and then delivers
  # matching events synchronously as they are appended.
  #
  # Every instance is its own log, so +namespace:+ changes nothing here; it
  # is accepted (and validated) so a store can be built the same way
  # whichever backend it turns out to be.
  class InMemoryStore
    include StoreInstrumentation

    # The Namespace this store was built with.
    attr_reader :namespace

    def initialize(upcaster: nil, subscribe_instrumentation: :event, namespace: nil)
      @upcaster = upcaster
      @subscribe_instrumentation = subscribe_instrumentation_mode(subscribe_instrumentation)
      @namespace = Namespace.wrap(namespace)
      @rows = []
      @ids = Set.new
      @next_position = 1
      @listeners = []
    end

    def read(query)
      instrument_read(each_matching(query, after: nil), query, nil)
    end

    def read_from(query, after:)
      instrument_read(each_matching(query, after: after), query, after)
    end

    # The sequence position of the last stored event, nil on an empty store.
    def last_position
      @rows.last&.fetch(:sequence_position)
    end

    # Same contract as SqlStore#append, idempotency by event id included:
    # every id stored returns the stored events, some raises DuplicateEvent.
    def append(events, condition = nil)
      events = Array(events)
      raise ArgumentError, "append needs at least one event" if events.empty?

      instrument_append(events, condition) do |payload|
        ids = events.map(&:id).uniq
        if ids.all? { |id| @ids.include?(id) }
          payload[:replayed] = true
          next replay(ids)
        end
        reject_stored!(ids)
        raise ConditionNotMet, "conflicting event(s)" if condition && conflicting_events?(condition)

        # No id is stored, so at least the first event is written; a later
        # one is skipped only when it repeats an id within the batch.
        sequenced = events.filter_map { |event| insert(event) }
        notify_listeners
        sequenced
      end
    end

    # Same contract as SqlStore#import: keeps id, created_at and
    # schema_version, assigns fresh positions in order, skips stored ids.
    def import(events)
      events = Array(events)
      return [] if events.empty?

      instrument_import(events) do
        imported = events.filter_map do |event|
          insert(event, created_at: (event.created_at || Time.now).floor(6), schema_version: event.schema_version || 1)
        end
        notify_listeners unless imported.empty?
        imported
      end
    end

    def subscribe(query, after: nil, &block)
      listener = { query: query, last_position: after, block: block }
      deliver(listener, :catch_up)
      @listeners << listener
      nil
    end

    # Same contract as SqlStore#settled. Single-threaded, so nothing is ever
    # in flight: the count alone decides.
    def settled(checks)
      checks.map do |check|
        matching = each_matching(check.query, after: check.after)
        matching.count { |event| event.sequence_position <= check.through } == check.count
      end
    end

    # #settled for one check.
    def settled?(query, after:, through:, count:)
      settled([SettleCheck.new(query: query, after: after, through: through, count: count)]).first
    end

    private

    def each_matching(query, after:)
      Enumerator.new do |yielder|
        index = 0
        while index < @rows.length
          row = @rows.fetch(index)
          index += 1
          next if after && row.fetch(:sequence_position) <= after
          next unless matches?(query, row)

          yielder << row_to_sequenced_event(row)
        end
      end
    end

    # Some of +ids+ stored (all of them is a replay, handled before).
    def reject_stored!(ids)
      stored = ids.select { |id| @ids.include?(id) }
      raise DuplicateEvent, stored unless stored.empty?
    end

    # The stored events with these ids, in log order.
    def replay(ids)
      @rows.filter_map { |row| row_to_sequenced_event(row) if ids.include?(row.fetch(:event_id)) }
    end

    def insert(event, created_at: Time.now, schema_version: 1)
      return nil unless @ids.add?(event.id)

      row = {
        sequence_position: @next_position,
        event_id: event.id,
        type: event.type,
        data: JSON.generate(event.data),
        tags: event.tags,
        causation_id: event.causation_id,
        correlation_id: event.correlation_id,
        schema_version: schema_version,
        created_at: created_at
      }
      @next_position += 1
      @rows << row

      row_to_appended_event(event, row)
    end

    def row_to_appended_event(event, row)
      SequencedEvent.new(
        sequence_position: row.fetch(:sequence_position),
        type: event.type,
        data: event.data,
        tags: event.tags,
        created_at: row.fetch(:created_at),
        id: event.id,
        causation_id: event.causation_id,
        correlation_id: event.correlation_id,
        schema_version: row.fetch(:schema_version)
      )
    end

    def row_to_sequenced_event(row)
      type = row.fetch(:type)
      data = JSON.parse(row.fetch(:data), symbolize_names: true)
      version = row.fetch(:schema_version)

      data, version = @upcaster.upcast(type, data, version) if @upcaster

      SequencedEvent.new(
        sequence_position: row.fetch(:sequence_position),
        type: type,
        data: data,
        tags: row.fetch(:tags),
        created_at: row.fetch(:created_at),
        id: row.fetch(:event_id),
        causation_id: row.fetch(:causation_id),
        correlation_id: row.fetch(:correlation_id),
        schema_version: version
      )
    end

    def matches?(query, row)
      return true if query.match_all?

      query.items.any? { |item| item_matches?(item, row) }
    end

    def item_matches?(item, row)
      type_match = item.event_types.empty? || item.event_types.include?(row.fetch(:type))
      tag_match = item.tags.all? { |tag| row.fetch(:tags).include?(tag) }
      type_match && tag_match
    end

    def conflicting_events?(condition)
      query = condition.fail_if_events_match
      after = condition.after
      @rows.any? do |row|
        (after.nil? || row.fetch(:sequence_position) > after) && matches?(query, row)
      end
    end

    def deliver(listener, phase)
      events = read_from(listener.fetch(:query), after: listener.fetch(:last_position))
      instrument_subscribe(events, listener.fetch(:query), phase) do |event|
        listener[:last_position] = event.sequence_position
        listener.fetch(:block).call(event)
      end
    end

    def notify_listeners
      @listeners.each { |listener| deliver(listener, :live) }
    end
  end
end
