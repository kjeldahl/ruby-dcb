require "logger"

module DcbEventStore
  # Observability adapter that renders instrumentation events the way an
  # ordinary Rails app renders SQL query metrics. ActiveRecord logs lines
  # like `User Load (0.5ms)  SELECT ...` from its own LogSubscriber: a
  # bold, colored label with the duration in parentheses, written to the
  # Rails logger at debug level. This adapter does the same for `*.dcb`
  # events so event-store activity blends into the surrounding query log:
  #
  #   DCB Append (1.4ms)  store=DcbEventStore::Store event_count=2 ...
  #
  # It reuses the same ANSI color codes ActiveSupport::LogSubscriber uses,
  # but deliberately does not depend on Rails/ActiveSupport: when Rails is
  # loaded it logs to Rails.logger, otherwise to $stdout. Attach it during
  # initialization (e.g. from a Rails initializer):
  #
  #   DcbEventStore::RailsLogSubscriber.new.attach_to
  #
  # Pass logger:, pattern: or colorize: to override the defaults.
  class RailsLogSubscriber
    DEFAULT_PATTERN = /\.dcb\z/

    CLEAR   = "\e[0m".freeze
    BOLD    = "\e[1m".freeze
    RED     = "\e[31m".freeze
    MAGENTA = "\e[35m".freeze
    CYAN    = "\e[36m".freeze

    def initialize(logger: default_logger, pattern: DEFAULT_PATTERN, colorize: true)
      @logger = logger
      @pattern = pattern
      @colorize = colorize
    end

    # Subscribes this adapter to the given Notifications instance
    # (the global one by default) and returns the subscription handle.
    def attach_to(notifications = DcbEventStore.instrumentation)
      notifications.subscribe(@pattern) { |event| call(event) }
    end

    # Logs at debug, matching how SQL queries are logged: the block is only
    # evaluated when the logger's level admits debug output.
    def call(event)
      @logger.debug { format_event(event) }
    end

    private

    def default_logger
      return Rails.logger if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger

      Logger.new($stdout)
    end

    def format_event(event)
      color = event.error ? RED : CYAN
      label = colorize("#{label_for(event.name)} (#{duration_ms(event)}ms)", color, bold: true)
      "  #{label}  #{colorize(body(event), event.error ? RED : MAGENTA)}"
    end

    def label_for(name)
      words = name.delete_suffix(".dcb").split("_").map(&:capitalize).join(" ")
      "DCB #{words}"
    end

    def duration_ms(event)
      (event.duration * 1000).round(1)
    end

    def body(event)
      parts = event.payload.reject { |_key, value| value.nil? }
                   .map { |key, value| "#{key}=#{format_value(value)}" }
      parts << "error=#{event.error.class} #{event.error}" if event.error
      parts.join(" ")
    end

    def format_value(value)
      value.is_a?(Array) ? "[#{value.join(',')}]" : value
    end

    def colorize(text, color, bold: false)
      return text unless @colorize

      "#{BOLD if bold}#{color}#{text}#{CLEAR}"
    end
  end
end
