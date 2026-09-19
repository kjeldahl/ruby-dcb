require_relative "dcb_event_store/version"
require_relative "dcb_event_store/notifications"
require_relative "dcb_event_store/active_support_instrumentation"
require_relative "dcb_event_store/store_instrumentation"
require_relative "dcb_event_store/log_subscriber"
require_relative "dcb_event_store/rails_log_subscriber"
require_relative "dcb_event_store/appsignal_subscriber"
require_relative "dcb_event_store/event"
require_relative "dcb_event_store/sequenced_event"
require_relative "dcb_event_store/query"
require_relative "dcb_event_store/append_condition"
require_relative "dcb_event_store/condition_not_met"
require_relative "dcb_event_store/in_memory_store"
require_relative "dcb_event_store/snapshot"
require_relative "dcb_event_store/materialized_streams"
require_relative "dcb_event_store/projection"
require_relative "dcb_event_store/decision_model"
require_relative "dcb_event_store/upcaster"
require_relative "dcb_event_store/client"

module DcbEventStore
  # The SQL backends load on first reference rather than with the gem, so an
  # application pulls in only the backend it constructs — and only that
  # driver's code paths. InMemoryStore stays eager: it needs no driver.
  autoload :SqlStore,      File.expand_path("dcb_event_store/sql_store", __dir__)
  autoload :PostgresStore, File.expand_path("dcb_event_store/postgres_store", __dir__)
  autoload :SqliteStore,   File.expand_path("dcb_event_store/sqlite_store", __dir__)

  # Snapshot stores follow the same rule: the in-memory one is driver-free,
  # the SQL ones load with the backend they persist through.
  module Snapshots
    autoload :InMemorySnapshotStore, File.expand_path("dcb_event_store/snapshots/in_memory_snapshot_store", __dir__)
    autoload :PostgresSnapshotStore, File.expand_path("dcb_event_store/snapshots/postgres_snapshot_store", __dir__)
    autoload :SqliteSnapshotStore,   File.expand_path("dcb_event_store/snapshots/sqlite_snapshot_store", __dir__)
  end

  # The deprecated pre-rename aliases all live in store.rb, which references
  # PostgresStore and so triggers its autoload in turn.
  autoload :Store,         File.expand_path("dcb_event_store/store", __dir__)
  autoload :Schema,        File.expand_path("dcb_event_store/store", __dir__)
  autoload :PgArrayCodec,  File.expand_path("dcb_event_store/store", __dir__)

  class << self
    # Process-wide Notifications instance used by all instrumentation
    # emission points. Replaceable, e.g. with a test-local instance.
    attr_accessor :instrumentation
  end

  self.instrumentation = Notifications.new
end

# Rails integration: loaded only inside a Rails process (Bundler.require
# happens after config/application.rb has required rails), and the only
# place the gem touches Rails at all. It wires the instrumentation up so a
# Rails application logs store operations without an initializer of its own.
require_relative "dcb_event_store/railtie" if defined?(Rails::Railtie)
