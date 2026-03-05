require "securerandom"

module DcbEventStore
  class Client
    def initialize(store, correlation_id: nil, causation_id: nil)
      @store = store
      @correlation_id = correlation_id || SecureRandom.uuid
      @causation_id = causation_id
    end

    attr_reader :correlation_id, :causation_id

    def append(events, condition = nil)
      events = Array(events).map { |e| stamp(e) }
      @store.append(events, condition)
    end

    def read(query) = @store.read(query)
    def read_from(query, after:) = @store.read_from(query, after: after)

    def caused_by(event)
      Client.new(
        @store,
        correlation_id: event.correlation_id || @correlation_id,
        causation_id: event.id
      )
    end

    private

    def stamp(event)
      Event.new(
        type: event.type,
        data: event.data,
        tags: event.tags,
        id: event.id,
        causation_id: event.causation_id || @causation_id,
        correlation_id: event.correlation_id || @correlation_id
      )
    end
  end
end
