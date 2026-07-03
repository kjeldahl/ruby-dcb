require "logger"

module DcbEventStore
  # Proof-of-concept observability adapter: writes one log line per
  # instrumentation event. Serves as the reference for richer connectors
  # (AppSignal, Prometheus, ...): subscribe to a Notifications instance and
  # translate the published events into the target system's format.
  class LogSubscriber
    DEFAULT_PATTERN = /\.dcb\z/

    def initialize(logger: Logger.new($stdout), pattern: DEFAULT_PATTERN)
      @logger = logger
      @pattern = pattern
    end

    # Subscribes this adapter to the given Notifications instance
    # (the global one by default) and returns the subscription handle.
    def attach_to(notifications = DcbEventStore.instrumentation)
      notifications.subscribe(@pattern) { |event| call(event) }
    end

    def call(event)
      if event.error
        @logger.error(format_event(event))
      else
        @logger.info(format_event(event))
      end
    end

    private

    def format_event(event)
      parts = ["#{event.name} (#{(event.duration * 1000).round(2)}ms)"]
      parts += event.payload.reject { |_key, value| value.nil? }
                    .map { |key, value| "#{key}=#{format_value(value)}" }
      parts << "error=#{event.error.class} #{event.error}" if event.error
      parts.join(" ")
    end

    def format_value(value)
      value.is_a?(Array) ? "[#{value.join(',')}]" : value
    end
  end
end
