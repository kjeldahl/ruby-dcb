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
  # Events are immutable and positions only grow, so reads go through
  # per-type and per-tag lists of positions, each sorted by construction,
  # rather than scanning the log: a read costs what it matches, not what is
  # stored.
  #
  # Every instance is its own log, so +namespace:+ changes nothing here; it
  # is accepted (and validated) so a store can be built the same way
  # whichever backend it turns out to be.
  class InMemoryStore
    include StoreInstrumentation

    EMPTY = [].freeze
    private_constant :EMPTY

    # The Namespace this store was built with.
    attr_reader :namespace

    def initialize(upcaster: nil, subscribe_instrumentation: :event, namespace: nil)
      @upcaster = upcaster
      @subscribe_instrumentation = subscribe_instrumentation_mode(subscribe_instrumentation)
      @namespace = Namespace.wrap(namespace)
      @rows = []
      @positions_by_id = {}
      @positions_by_type = {}
      @positions_by_tag = {}
      @next_position = 1
      @listeners = []
    end

    # Same contract as SqlStore#read.
    def read(query, backwards: false, limit: nil)
      read_with(query, ReadOptions.new(backwards: backwards, limit: limit))
    end

    # Same contract as SqlStore#read_from.
    def read_from(query, after: nil, before: nil, backwards: false, limit: nil)
      read_with(query, ReadOptions.new(after: after, before: before, backwards: backwards, limit: limit))
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
        if ids.all? { |id| @positions_by_id.key?(id) }
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
        matching = each_matching(check.query, ReadOptions.new(after: check.after))
        matching.count { |event| event.sequence_position <= check.through } == check.count
      end
    end

    # #settled for one check.
    def settled?(query, after:, through:, count:)
      settled([SettleCheck.new(query: query, after: after, through: through, count: count)]).first
    end

    private

    def read_with(query, options)
      instrument_read(each_matching(query, options), query, options)
    end

    def each_matching(query, options)
      Enumerator.new do |yielder|
        yielded = 0
        each_position(query, options) do |position|
          yielder << row_to_sequenced_event(row_at(position))
          yielded += 1
          break if yielded == options.limit
        end
      end
    end

    # The positions matching +query+ within the read's bound, in its
    # direction. A forward read asks again past the rows it searched when
    # more were appended while it ran (a subscriber appending from its
    # block), as a SQL store's next page would see them.
    def each_position(query, options, &)
      limit = options.limit
      if options.backwards
        return matching_positions(query, nil, options.before, limit: limit, backwards: true).reverse_each(&)
      end

      after = options.after
      loop do
        searched = @rows.length
        matching_positions(query, after, nil, limit: limit).each(&)
        break if @rows.length == searched

        # Rows were appended from the block, so this search yielded a row
        # past +after+: everything up to +searched+ is done.
        after = searched
      end
    end

    # Ascending positions matching +query+, strictly between +after+ and
    # +before+ (either nil for no bound). With a +limit+ each list gives up
    # at most that many from the read's end, enough for the read to stop
    # after +limit+ events. A Range for Query.all, so an unfiltered read
    # with a limit does not list the whole log.
    def matching_positions(query, after, before, limit: nil, backwards: false)
      first = after ? [after + 1, 1].max : 1
      last = before ? [before - 1, @rows.length].min : @rows.length
      return first..last if query.match_all?

      positions = query.items.flat_map do |item|
        candidate_lists(item).flat_map do |list|
          matching_in(item, between(list, after, before), limit, backwards)
        end
      end
      positions.sort!
      positions.uniq!
      positions
    end

    # The positions of +slice+ that match +item+: all of them, or the first
    # +limit+ from the read's end.
    def matching_in(item, slice, limit, backwards)
      return slice.select { |position| item_matches?(item, row_at(position)) } unless limit

      walk = backwards ? slice.reverse_each : slice
      walk.lazy.select { |position| item_matches?(item, row_at(position)) }.first(limit)
    end

    # The lists that between them hold every position matching +item+,
    # the fewest positions to check: its shortest tag list, or all its type
    # lists together when they are shorter still (a tie goes to the tag
    # list: one list, nothing to merge).
    def candidate_lists(item)
      tag_list = item.tags.map { |tag| @positions_by_tag.fetch(tag, EMPTY) }.min_by(&:length)
      type_lists = item.event_types.map { |type| @positions_by_type.fetch(type, EMPTY) }
      return type_lists unless tag_list
      return [tag_list] if type_lists.empty? || tag_list.length <= type_lists.sum(&:length)

      type_lists
    end

    # The slice of the ascending +list+ strictly between +after+ and +before+
    # (a nil end leaves that side of the range open).
    def between(list, after, before)
      first = after && (list.bsearch_index { |position| position > after } || list.length)
      last = before && list.bsearch_index { |position| position >= before }
      list[first...last]
    end

    # Positions are 1, 2, 3, ... with no gaps, so a row's index is its
    # position less one.
    def row_at(position)
      @rows.fetch(position - 1)
    end

    # Some of +ids+ stored (all of them is a replay, handled before).
    def reject_stored!(ids)
      stored = ids.select { |id| @positions_by_id.key?(id) }
      raise DuplicateEvent, stored unless stored.empty?
    end

    # The stored events with these ids, in log order.
    def replay(ids)
      ids.map { |id| @positions_by_id.fetch(id) }.sort.map { |position| row_to_sequenced_event(row_at(position)) }
    end

    def insert(event, created_at: Time.now, schema_version: 1)
      return nil if @positions_by_id.key?(event.id)

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
      index!(row)

      row_to_appended_event(event, row)
    end

    def index!(row)
      position = row.fetch(:sequence_position)
      @positions_by_id[row.fetch(:event_id)] = position
      (@positions_by_type[row.fetch(:type)] ||= []) << position
      row.fetch(:tags).each { |tag| (@positions_by_tag[tag] ||= []) << position }
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

    def item_matches?(item, row)
      type_match = item.event_types.empty? || item.event_types.include?(row.fetch(:type))
      tag_match = item.tags.all? { |tag| row.fetch(:tags).include?(tag) }
      type_match && tag_match
    end

    def conflicting_events?(condition)
      query = condition.fail_if_events_match
      after = condition.after
      return matching_positions(query, after, nil).any? if query.match_all?

      query.items.any? do |item|
        candidate_lists(item).any? do |list|
          between(list, after, nil).any? { |position| item_matches?(item, row_at(position)) }
        end
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
