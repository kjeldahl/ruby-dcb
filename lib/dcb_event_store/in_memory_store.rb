require "json"

module DcbEventStore
  # In-memory drop-in replacement for Store, intended for fast tests
  # (e.g. mutation testing) where a live PostgreSQL server is too slow.
  #
  # Not thread-safe: it is meant for single-threaded test runs only.
  # Unlike the PostgreSQL-backed Store, #subscribe does not block waiting
  # for notifications; it catches up on existing events and then delivers
  # matching events synchronously as they are appended.
  class InMemoryStore
    include StoreInstrumentation

    def initialize(upcaster: nil, subscribe_instrumentation: :event)
      @upcaster = upcaster
      @subscribe_instrumentation = subscribe_instrumentation_mode(subscribe_instrumentation)
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

    def append(events, condition = nil)
      events = Array(events)
      instrument_append(events, condition) do
        raise ConditionNotMet, "conflicting event(s)" if condition && conflicting_events?(condition)

        sequenced = events.filter_map { |event| insert(event) }
        notify_listeners unless sequenced.empty?
        sequenced
      end
    end

    def subscribe(query, after: nil, &block)
      listener = { query: query, last_position: after, block: block }
      deliver(listener, :catch_up)
      @listeners << listener
      nil
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

    def insert(event)
      return nil unless @ids.add?(event.id)

      row = {
        sequence_position: @next_position,
        event_id: event.id,
        type: event.type,
        data: JSON.generate(event.data),
        tags: event.tags,
        causation_id: event.causation_id,
        correlation_id: event.correlation_id,
        schema_version: 1,
        created_at: Time.now
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
        schema_version: 1
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
      return false if item.event_types.empty? && item.tags.empty?

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
