module DcbEventStore
  # A store decorator that materializes streams in process.
  #
  # In a DCB store the "stream" of an entity is whatever a QueryItem selects
  # (a set of types and tags), and every read re-selects and re-decodes it.
  # This wrapper keeps the decoded SequencedEvents of each item it has
  # served; on the next read touching the same item it only asks the
  # underlying store for the events after the last one it holds (a
  # read_from) and appends them. A Query of several items is served by
  # merging the items' streams. The database work per read shrinks from "the
  # whole stream" to "what is new", and the decoding work with it; the fold
  # still runs over the whole stream, so the cost stays proportional to its
  # length — for a bounded cost use snapshots.
  #
  # Compared to snapshots this needs no naming, no versioning and no
  # serialization (the events are immutable facts, so a materialized stream
  # cannot go stale the way a snapshot of derived state can), but it is per
  # process, bounded by memory and rebuilt on every restart.
  #
  # Streams are evicted least-recently-used once +max_streams+ or
  # +max_events+ (summed over all streams) is exceeded. A read_from is
  # served the same way, filtered to the positions after +after+; a query
  # with no items (Query.all) is one stream of its own. Everything else
  # (append, subscribe) passes through untouched. A Mutex serializes the
  # cache; reads of the same wrapper from several threads therefore
  # serialize too.
  #
  # Every read publishes one "stream.dcb" event: store:, query:, after:,
  # streams: (items involved), hits:/misses: (streams that existed / had to
  # be built), fetched_count: (events pulled from the store this time),
  # event_count: (events served) and evicted: (streams dropped to stay
  # within the limits). The wrapped store's own read.dcb events still fire
  # for what reached the database. The hit rate and fetched_count against
  # event_count are the signal that the cache is doing its job.
  class MaterializedStreams
    Stream = Struct.new(:events, :last_position)

    attr_reader :store

    def initialize(store, max_streams: 1_000, max_events: 1_000_000)
      @store = store
      @max_streams = max_streams
      @max_events = max_events
      @streams = {}
      @event_count = 0
      @mutex = Mutex.new
    end

    def read(query)
      merged(query, nil).each
    end

    def read_from(query, after:)
      merged(query, after).each
    end

    def append(events, condition = nil) = @store.append(events, condition)
    def subscribe(query, after: nil, &) = @store.subscribe(query, after: after, &)

    def size = @mutex.synchronize { @streams.size }
    def event_count = @mutex.synchronize { @event_count }

    def clear
      @mutex.synchronize do
        @streams.clear
        @event_count = 0
      end
      nil
    end

    private

    # The events matching +query+ after +after+ (nil for all), from its
    # items' streams: a single item's stream as is, several merged in
    # sequence order with an event matching more than one item kept once.
    def merged(query, after)
      payload = { store: self.class.name, query: query, after: after }
      DcbEventStore.instrumentation.instrument(StoreInstrumentation::STREAM_EVENT, payload) do |inner|
        @mutex.synchronize do
          @stats = { hits: 0, misses: 0, fetched_count: 0, evicted: 0 }
          streams = item_queries(query).map { |item_query| materialize(item_query) }
          events = events_of(streams)
          events = events.select { |e| e.sequence_position > after } if after
          inner.merge!(streams: streams.size, **@stats, event_count: events.size)
          events
        end
      end
    end

    def events_of(streams)
      return streams.first.events if streams.size == 1

      by_position = {}
      streams.each { |stream| stream.events.each { |e| by_position[e.sequence_position] ||= e } }
      by_position.values.sort_by!(&:sequence_position)
    end

    def item_queries(query)
      return [query] if query.match_all?

      query.items.map { |item| Query.new([item]) }
    end

    # Returns the stream for a one-item +query+, extended with what the store
    # has after its last event, or built from a full read when there is none
    # yet.
    def materialize(query)
      key = query.fingerprint
      stream = @streams.delete(key) # re-inserted below, so it becomes most recent

      if stream
        @stats[:hits] += 1
        fresh = @store.read_from(query, after: stream.last_position).to_a
      else
        @stats[:misses] += 1
        fresh = @store.read(query).to_a
        stream = Stream.new([], nil)
      end

      unless fresh.empty?
        stream.events.concat(fresh)
        stream.last_position = fresh.last.sequence_position
        @event_count += fresh.size
        @stats[:fetched_count] += fresh.size
      end

      @streams[key] = stream
      evict
      stream
    end

    def evict
      while @streams.size > @max_streams || (@event_count > @max_events && @streams.size > 1)
        _key, oldest = @streams.shift
        @event_count -= oldest.events.size
        @stats[:evicted] += 1
      end
    end
  end
end
