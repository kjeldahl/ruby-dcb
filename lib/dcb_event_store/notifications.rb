module DcbEventStore
  # Lightweight publish/subscribe instrumentation engine, modeled on
  # ActiveSupport::Notifications. Emission points around the gem call
  # #instrument; observability adapters (loggers, AppSignal, Prometheus,
  # ...) call #subscribe and translate the published Event objects into
  # their target system's format.
  #
  # Instrumentation is optional: with no matching subscribers, #instrument
  # just yields, skipping timing and event construction entirely.
  class Notifications
    # Published to subscribers for every instrumented operation.
    # started_at/finished_at are monotonic clock readings (seconds);
    # error carries the exception when the instrumented block raised.
    Event = Data.define(:name, :payload, :started_at, :finished_at, :error) do
      def duration
        finished_at - started_at
      end
    end

    Subscription = Data.define(:pattern, :block) do
      def matches?(name)
        case pattern
        when nil then true
        when Regexp then pattern.match?(name)
        else pattern == name
        end
      end
    end

    def initialize
      @mutex = Mutex.new
      @subscriptions = [].freeze
    end

    # Registers a subscriber for events whose name matches pattern:
    # a String (exact match), a Regexp, or nil for all events.
    # Returns a handle accepted by #unsubscribe.
    def subscribe(pattern = nil, &block)
      raise ArgumentError, "a subscriber block is required" unless block

      subscription = Subscription.new(pattern: pattern, block: block)
      @mutex.synchronize { @subscriptions = [*@subscriptions, subscription].freeze }
      subscription
    end

    def unsubscribe(subscription)
      @mutex.synchronize { @subscriptions = (@subscriptions - [subscription]).freeze }
      nil
    end

    def listening?(name)
      @subscriptions.any? { |subscription| subscription.matches?(name) }
    end

    # Times the block and publishes an Event to matching subscribers.
    # The payload hash is yielded so the block can enrich it with results
    # (counts, positions). Exceptions are captured on the event, published,
    # and re-raised.
    def instrument(name, payload = {})
      subscriptions = @subscriptions.select { |subscription| subscription.matches?(name) }
      return yield(payload) if subscriptions.empty?

      started_at = monotonic_time
      error = nil
      begin
        yield(payload)
      rescue StandardError => e
        error = e
        raise
      ensure
        event = Event.new(name: name, payload: payload, started_at: started_at,
                          finished_at: monotonic_time, error: error)
        subscriptions.each { |subscription| subscription.block.call(event) }
      end
    end

    private

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
