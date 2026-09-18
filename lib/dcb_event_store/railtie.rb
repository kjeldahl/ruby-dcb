require "rails/railtie"

module DcbEventStore
  # Zero-configuration Rails integration: in a Rails process the store is
  # observable out of the box, without an initializer in the application.
  #
  # The gem publishes a *.dcb event for every operation it performs
  # (append.dcb, read.dcb, subscribe.dcb, projection.dcb,
  # decision_model.dcb) but emits nothing while no one subscribes, so this
  # railtie does the two things that make them visible:
  #
  # 1. swaps the engine for ActiveSupportInstrumentation, routing every
  #    event through ActiveSupport::Notifications, where APM agents,
  #    lograge and plain AS::N subscribers already look -- and where dcb
  #    events nest inside the surrounding request/job span;
  # 2. attaches RailsLogSubscriber, which renders them the way
  #    ActiveRecord renders SQL queries, at debug level:
  #
  #      DCB Append (1.4ms)  store=DcbEventStore::SqliteStore event_count=1 ...
  #
  # Both halves are configurable from config/application.rb or an
  # environment file:
  #
  #   config.dcb_event_store.instrumentation = :standalone  # keep the gem's
  #     # own engine (default :active_support). Assign DcbEventStore
  #     # .instrumentation yourself afterwards for a custom engine.
  #   config.dcb_event_store.log = false        # no log subscriber at all
  #   config.dcb_event_store.logger = MyLogger.new  # default: Rails.logger
  #   config.dcb_event_store.pattern = "append.dcb" # default: every *.dcb event
  #   config.dcb_event_store.colorize = false   # default: config.colorize_logging
  #
  # After boot the attached adapter and its subscription handle are on the
  # same options object (log_subscriber / log_subscription), so an
  # application can detach the logger later:
  #
  #   options = Rails.application.config.dcb_event_store
  #   DcbEventStore.instrumentation.unsubscribe(options.log_subscription)
  class Railtie < ::Rails::Railtie
    config.dcb_event_store = ActiveSupport::OrderedOptions.new

    # Runs after :initialize_logger so Rails.logger is the real application
    # logger, and once per boot rather than per reload: subscriptions are
    # process-wide and would stack up one copy per reload.
    initializer "dcb_event_store.instrumentation", after: :initialize_logger do |app|
      DcbEventStore::Railtie.install(app)
    end

    # Applies the configuration above to the global instrumentation engine.
    # Returns the attached log subscriber, or nil when logging is off.
    def self.install(app)
      options = app.config.dcb_event_store
      install_engine(options)
      install_log_subscriber(app, options)
    end

    def self.install_engine(options)
      case options.fetch(:instrumentation, :active_support)
      when :active_support then DcbEventStore.instrumentation = ActiveSupportInstrumentation.new
      when :standalone then nil # keep whichever engine is already assigned
      else
        raise ArgumentError,
              "config.dcb_event_store.instrumentation must be :active_support or :standalone, " \
              "got #{options[:instrumentation].inspect}"
      end
    end

    def self.install_log_subscriber(app, options)
      return nil unless options.fetch(:log, true)

      subscriber = RailsLogSubscriber.new(
        logger: options[:logger] || Rails.logger,
        pattern: options[:pattern] || RailsLogSubscriber::DEFAULT_PATTERN,
        colorize: colorize?(app, options)
      )
      options[:log_subscriber] = subscriber
      options[:log_subscription] = subscriber.attach_to
      subscriber
    end

    # An unset colorize: follows Rails' own logging setting, which is what
    # turns ANSI codes off for a non-TTY log destination.
    def self.colorize?(app, options)
      colorize = options[:colorize]
      colorize.nil? ? app.config.colorize_logging : colorize
    end

    private_class_method :install_engine, :install_log_subscriber, :colorize?
  end
end
