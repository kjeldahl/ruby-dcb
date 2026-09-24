require "simplecov"
require "simplecov-json"

SimpleCov.start do
  enable_coverage :branch

  add_filter "/test/"
  add_filter "/examples/"

  add_group "Core", [
    "lib/dcb_event_store.rb",
    "lib/dcb_event_store/sql_store.rb",
    "lib/dcb_event_store/sql_store/sql_builder.rb",
    "lib/dcb_event_store/sql_store/row_mapper.rb",
    "lib/dcb_event_store/sql_store/timestamp.rb",
    "lib/dcb_event_store/store.rb",
    "lib/dcb_event_store/client.rb"
  ]
  add_group "Backends", [
    "lib/dcb_event_store/postgres_store.rb",
    "lib/dcb_event_store/postgres_store/dialect.rb",
    "lib/dcb_event_store/postgres_store/array_codec.rb",
    "lib/dcb_event_store/postgres_store/lock_keys.rb",
    "lib/dcb_event_store/sqlite_store.rb",
    "lib/dcb_event_store/sqlite_store/dialect.rb",
    "lib/dcb_event_store/in_memory_store.rb"
  ]
  add_group "Models", ["lib/dcb_event_store/event.rb", "lib/dcb_event_store/query.rb"]
  add_group "Features", [
    "lib/dcb_event_store/projection.rb",
    "lib/dcb_event_store/decision_model.rb",
    "lib/dcb_event_store/upcaster.rb",
    "lib/dcb_event_store/event_file.rb",
    "lib/dcb_event_store/cli.rb",
    "lib/dcb_event_store/subscription.rb"
  ]
  add_group "Schema", [
    "lib/dcb_event_store/postgres_store/schema.rb",
    "lib/dcb_event_store/sqlite_store/schema.rb"
  ]
  add_group "Instrumentation", [
    "lib/dcb_event_store/notifications.rb",
    "lib/dcb_event_store/active_support_instrumentation.rb",
    "lib/dcb_event_store/store_instrumentation.rb",
    "lib/dcb_event_store/log_subscriber.rb",
    "lib/dcb_event_store/rails_log_subscriber.rb",
    "lib/dcb_event_store/appsignal_subscriber.rb"
  ]

  if ENV["CI"]
    formatter SimpleCov::Formatter::MultiFormatter.new(
      [
        SimpleCov::Formatter::HTMLFormatter,
        SimpleCov::Formatter::JSONFormatter
      ]
    )
  end
end

require "minitest/autorun" unless defined?(Mutant)
require "mutant/minitest/coverage"
require "dcb_event_store"
