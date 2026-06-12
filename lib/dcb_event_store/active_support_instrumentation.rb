module DcbEventStore
  # Drop-in replacement for the Notifications engine that routes all
  # instrumentation through ActiveSupport::Notifications. Assign it in a
  # Rails initializer to make event-store activity visible to the entire
  # Rails instrumentation ecosystem (APM agents, lograge, custom
  # ActiveSupport::Notifications.subscribe blocks):
  #
  #   # config/initializers/dcb_event_store.rb
  #   DcbEventStore.instrumentation = DcbEventStore::ActiveSupportInstrumentation.new
  #
  #   ActiveSupport::Notifications.subscribe(/\.dcb\z/) do |event|
  #     Rails.logger.info "#{event.name} (#{event.duration.round(1)}ms)"
  #   end
  #
  # Emission points are unchanged: ActiveSupport::Notifications.instrument
  # does the timing, so dcb events nest correctly inside surrounding
  # spans. Failures follow the ActiveSupport convention (payload
  # :exception / :exception_object) in addition to being re-raised.
  #
  # The DcbEventStore subscriber API (subscribe/unsubscribe/listening?)
  # keeps working against this engine, translating ActiveSupport
  # notifications back into Notifications::Event objects, so adapters like
  # LogSubscriber and RailsLogSubscriber can attach_to it unchanged.
  #
  # ActiveSupport is required lazily on construction; the gem itself does
  # not depend on it.
  class ActiveSupportInstrumentation
    def initialize
      require "active_support"
      require "active_support/notifications"
    rescue LoadError
      raise LoadError,
            "DcbEventStore::ActiveSupportInstrumentation requires the activesupport gem; " \
            "add it to your Gemfile or use DcbEventStore::Notifications instead"
    end

    # Registers a subscriber for events whose name matches pattern (String
    # for exact match, Regexp, or nil for all events), like
    # Notifications#subscribe. The block receives Notifications::Event
    # objects. Returns a handle accepted by #unsubscribe.
    def subscribe(pattern = nil, &block)
      raise ArgumentError, "a subscriber block is required" unless block

      ActiveSupport::Notifications.monotonic_subscribe(pattern) do |name, started_at, finished_at, _id, payload|
        block.call(to_event(name, started_at, finished_at, payload))
      end
    end

    def unsubscribe(subscription)
      ActiveSupport::Notifications.unsubscribe(subscription)
      nil
    end

    def listening?(name)
      ActiveSupport::Notifications.notifier.listening?(name)
    end

    def instrument(name, payload = {}, &)
      ActiveSupport::Notifications.instrument(name, payload, &)
    end

    private

    def to_event(name, started_at, finished_at, payload)
      error = payload[:exception_object]
      Notifications::Event.new(
        name: name,
        payload: payload.except(:exception, :exception_object),
        started_at: started_at,
        finished_at: finished_at,
        error: error
      )
    end
  end
end
