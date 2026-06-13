require_relative "dcb_event_store/version"
require_relative "dcb_event_store/notifications"
require_relative "dcb_event_store/active_support_instrumentation"
require_relative "dcb_event_store/store_instrumentation"
require_relative "dcb_event_store/log_subscriber"
require_relative "dcb_event_store/rails_log_subscriber"
require_relative "dcb_event_store/appsignal_subscriber"
require_relative "dcb_event_store/validation"
require_relative "dcb_event_store/event"
require_relative "dcb_event_store/sequenced_event"
require_relative "dcb_event_store/query"
require_relative "dcb_event_store/append_condition"
require_relative "dcb_event_store/schema"
require_relative "dcb_event_store/condition_not_met"
require_relative "dcb_event_store/store"
require_relative "dcb_event_store/in_memory_store"
require_relative "dcb_event_store/projection"
require_relative "dcb_event_store/decision_model"
require_relative "dcb_event_store/upcaster"
require_relative "dcb_event_store/client"

module DcbEventStore
  class << self
    # Process-wide Notifications instance used by all instrumentation
    # emission points. Replaceable, e.g. with a test-local instance.
    attr_accessor :instrumentation

    # Global flag to enable/disable event validation.
    # When true, Event.new will validate type, data, and tags.
    # Default is nil (disabled for backward compatibility).
    # Set to true in production to enforce validation.
    attr_accessor :validate_events
  end

  self.instrumentation = Notifications.new
  self.validate_events = nil
end
