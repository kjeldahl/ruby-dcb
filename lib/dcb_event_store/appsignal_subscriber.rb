module DcbEventStore
  # Observability adapter that translates instrumentation events into
  # AppSignal custom metrics (https://docs.appsignal.com/metrics/custom.html):
  #
  #   dcb.<operation>.duration   distribution (ms)  every event
  #   dcb.<operation>.errors     counter            events with an error
  #   dcb.append.events          counter            events actually written
  #   dcb.append.conflicts       counter            ConditionNotMet failures
  #   dcb.subscribe.delivered    counter            deliveries, tagged by phase
  #   dcb.subscribe.lag          distribution (ms)  live delivery lag
  #
  # Metrics are tagged with the emitting store (demodulized, e.g.
  # store=Store); dcb.subscribe.delivered additionally carries
  # phase=live/catch_up. Delivery lag is recorded only for the :live phase
  # - catch-up replays history, where large lag is expected and would
  # poison the staleness signal - and comes from lag: (per-event mode) or
  # max_lag: (batched mode).
  #
  # Works against either instrumentation engine, since metrics are
  # recorded after the fact. For spans inside request traces, route events
  # through ActiveSupportInstrumentation and wrap application calls with
  # Appsignal.instrument.
  #
  #   # e.g. in a Rails initializer (Gemfile: gem "appsignal")
  #   DcbEventStore::AppsignalSubscriber.new.attach_to
  #
  # The appsignal gem is required lazily on first use; this gem does not
  # depend on it. Only the stable public helpers Appsignal.increment_counter
  # and Appsignal.add_distribution_value are used, so a custom receiver can
  # be injected via appsignal: (also the test seam).
  class AppsignalSubscriber
    DEFAULT_PATTERN = /\.dcb\z/

    def initialize(appsignal: nil, prefix: "dcb", pattern: DEFAULT_PATTERN)
      @appsignal = appsignal
      @prefix = prefix
      @pattern = pattern
    end

    # Subscribes this adapter to the given Notifications instance
    # (the global one by default) and returns the subscription handle.
    def attach_to(notifications = DcbEventStore.instrumentation)
      notifications.subscribe(@pattern) { |event| call(event) }
    end

    def call(event)
      operation = event.name.delete_suffix(".dcb")
      tags = tags_for(event)

      appsignal.add_distribution_value(metric(operation, "duration"), event.duration * 1000, tags)
      appsignal.increment_counter(metric(operation, "errors"), 1, tags) if event.error

      case event.name
      when StoreInstrumentation::APPEND_EVENT then record_append(event, tags)
      when StoreInstrumentation::SUBSCRIBE_EVENT then record_subscribe(event, tags)
      end
    end

    private

    def appsignal
      @appsignal ||= begin
        require "appsignal"
        Appsignal
      rescue LoadError
        raise LoadError,
              "DcbEventStore::AppsignalSubscriber requires the appsignal gem; add it to your Gemfile"
      end
    end

    def metric(operation, name)
      "#{@prefix}.#{operation}.#{name}"
    end

    def tags_for(event)
      store = event.payload[:store]
      store ? { store: store.split("::").last } : {}
    end

    def record_append(event, tags)
      appended = event.payload[:appended_count]
      appsignal.increment_counter(metric("append", "events"), appended, tags) if appended&.positive?
      appsignal.increment_counter(metric("append", "conflicts"), 1, tags) if event.error.is_a?(ConditionNotMet)
    end

    def record_subscribe(event, tags)
      phase = event.payload[:phase]
      delivered = event.payload.fetch(:event_count, 1)
      if delivered.positive?
        appsignal.increment_counter(metric("subscribe", "delivered"), delivered, tags.merge(phase: phase))
      end

      lag = event.payload[:lag] || event.payload[:max_lag]
      appsignal.add_distribution_value(metric("subscribe", "lag"), lag * 1000, tags) if phase == :live && lag
    end
  end
end
