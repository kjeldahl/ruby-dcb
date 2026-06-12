module DcbEventStore
  class Projection
    attr_reader :initial_state, :handlers, :query

    def initialize(initial_state:, handlers:, query:)
      @initial_state = initial_state
      @handlers = handlers
      @query = query
    end

    def apply(state, event)
      handler = @handlers[event.type]
      handler ? handler.call(state, event) : state
    end

    def fold(events)
      DcbEventStore.instrumentation.instrument("projection.dcb", event_types: event_types) do |payload|
        count = 0
        state = events.reduce(@initial_state) do |acc, event|
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
