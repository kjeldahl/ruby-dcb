module DcbEventStore
  # Shared instrumentation emission for store implementations. Both Store
  # and InMemoryStore wrap their operations through these helpers so
  # subscribers observe identical events regardless of backend.
  #
  # Reads are lazy enumerators, so the "read.dcb" event is published when
  # the enumeration finishes, either by completing or by being exited
  # early (#first, break). event_count is the number of events yielded up
  # to that point. An external iterator that is merely abandoned (#next
  # without exhausting) publishes nothing.
  module StoreInstrumentation
    APPEND_EVENT = "append.dcb".freeze
    READ_EVENT = "read.dcb".freeze

    private

    def instrument_append(events, condition)
      DcbEventStore.instrumentation.instrument(
        APPEND_EVENT,
        store: self.class.name,
        event_count: events.size,
        event_types: events.map(&:type).uniq,
        condition: !condition.nil?
      ) do |payload|
        appended = yield
        payload[:appended_count] = appended.size
        payload[:last_position] = appended.last&.sequence_position
        appended
      end
    end

    def instrument_read(events, query, after)
      instrumentation = DcbEventStore.instrumentation
      return events unless instrumentation.listening?(READ_EVENT)

      Enumerator.new do |yielder|
        payload = { store: self.class.name, query: query, after: after }
        instrumentation.instrument(READ_EVENT, payload) do |inner|
          inner[:event_count] = 0
          events.each do |event|
            inner[:event_count] += 1
            yielder << event
          end
        end
      end
    end
  end
end
