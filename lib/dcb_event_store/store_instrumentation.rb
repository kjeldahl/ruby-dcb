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
  #
  # Subscriptions emit "subscribe.dcb" events whose payload includes the
  # delivery lag: the wall-clock time between an event being stored
  # (created_at) and its delivery to the subscriber block. Two caveats:
  #
  # - Clock skew: created_at is stamped by the PostgreSQL server clock
  #   while lag is measured against the consumer host's clock. When they
  #   are different machines the lag absorbs any skew between them and can
  #   even be slightly negative. Keep both hosts NTP-synced and treat lag
  #   as a trend/magnitude signal, not a precise measurement.
  # - InMemoryStore delivers synchronously on the appender's thread, so
  #   its lag is just in-process dispatch overhead (~0); events are
  #   emitted with the same shape so app tests can assert on them, but
  #   the lag values are only meaningful for the PostgreSQL-backed Store.
  #
  # Emission granularity is configured per store via the
  # subscribe_instrumentation: constructor option:
  #
  # - :event (default) - one event per delivered store event, with its
  #   sequence_position and lag; duration is the handler time.
  # - :batch - one event per delivery round (the whole catch-up, then one
  #   per NOTIFY wake-up), with event_count, last_position and max_lag;
  #   duration spans reading plus all handler calls in the round.
  module StoreInstrumentation
    APPEND_EVENT = "append.dcb".freeze
    READ_EVENT = "read.dcb".freeze
    SUBSCRIBE_EVENT = "subscribe.dcb".freeze
    SUBSCRIBE_MODES = %i[event batch].freeze

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

    def subscribe_instrumentation_mode(mode)
      unless SUBSCRIBE_MODES.include?(mode)
        valid = SUBSCRIBE_MODES.map(&:inspect).join(", ")
        raise ArgumentError,
              "subscribe_instrumentation must be one of [#{valid}], got #{mode.inspect}"
      end

      mode
    end

    # Delivers each event to the subscriber block, instrumented according
    # to the store's subscribe_instrumentation mode. Whether a delivery
    # round is instrumented is decided per round, so subscribers attached
    # mid-subscription observe subsequent rounds. Returns the sequence
    # position of the last delivered event, or nil if none were delivered.
    def instrument_subscribe(events, query, phase, &)
      instrumentation = DcbEventStore.instrumentation
      return deliver_plain(events, &) unless instrumentation.listening?(SUBSCRIBE_EVENT)

      if @subscribe_instrumentation == :batch
        deliver_batched(instrumentation, events, query, phase, &)
      else
        deliver_per_event(instrumentation, events, query, phase, &)
      end
    end

    def deliver_plain(events)
      last_position = nil
      events.each do |event|
        last_position = event.sequence_position
        yield event
      end
      last_position
    end

    def deliver_per_event(instrumentation, events, query, phase)
      last_position = nil
      events.each do |event|
        last_position = event.sequence_position
        payload = {
          store: self.class.name, query: query, phase: phase,
          sequence_position: event.sequence_position,
          lag: Time.now - event.created_at
        }
        instrumentation.instrument(SUBSCRIBE_EVENT, payload) { yield event }
      end
      last_position
    end

    def deliver_batched(instrumentation, events, query, phase)
      last_position = nil
      payload = { store: self.class.name, query: query, phase: phase }
      instrumentation.instrument(SUBSCRIBE_EVENT, payload) do |inner|
        inner[:event_count] = 0
        events.each do |event|
          last_position = event.sequence_position
          inner[:event_count] += 1
          inner[:last_position] = last_position
          # Events arrive oldest-first (ascending position), so the first
          # one carries the largest delivery lag for the round.
          inner[:max_lag] ||= Time.now - event.created_at
          yield event
        end
      end
      last_position
    end
  end
end
