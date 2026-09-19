module DcbEventStore
  class Projection
    attr_reader :initial_state, :handlers, :query, :snapshot

    # +snapshot+ is an optional Snapshot: with one, DecisionModel.build can
    # start the fold from a stored state instead of the initial one.
    def initialize(initial_state:, handlers:, query:, snapshot: nil)
      @initial_state = initial_state
      @handlers = handlers
      @query = query
      @snapshot = snapshot
    end

    def apply(state, event)
      handler = @handlers[event.type]
      handler ? handler.call(state, event) : state
    end

    # Folds +events+ onto +from+ (the initial state by default, or a
    # snapshot's state).
    def fold(events, from: @initial_state)
      DcbEventStore.instrumentation.instrument("projection.dcb", event_types: event_types) do |payload|
        count = 0
        state = events.reduce(from) do |acc, event|
          count += 1
          apply(acc, event)
        end
        payload[:event_count] = count
        state
      end
    end

    def event_types
      @handlers.keys
    end
  end
end
