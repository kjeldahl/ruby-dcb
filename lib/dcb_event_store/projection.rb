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
      events.reduce(@initial_state) { |state, event| apply(state, event) }
    end

    def event_types
      @handlers.keys
    end
  end
end
