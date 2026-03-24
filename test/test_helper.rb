require "simplecov"
require "simplecov-json"

SimpleCov.start do
  enable_coverage :branch

  add_filter "/test/"
  add_filter "/examples/"

  add_group "Core", ["lib/dcb_event_store.rb", "lib/dcb_event_store/store.rb", "lib/dcb_event_store/client.rb"]
  add_group "Models", ["lib/dcb_event_store/event.rb", "lib/dcb_event_store/query.rb"]
  add_group "Features", [
    "lib/dcb_event_store/projection.rb",
    "lib/dcb_event_store/decision_model.rb",
    "lib/dcb_event_store/upcaster.rb",
    "lib/dcb_event_store/subscription.rb"
  ]
  add_group "Schema", ["lib/dcb_event_store/schema.rb"]

  if ENV["CI"]
    formatter SimpleCov::Formatter::MultiFormatter.new(
      [
        SimpleCov::Formatter::HTMLFormatter,
        SimpleCov::Formatter::JSONFormatter
      ]
    )
  end
end

require "minitest/autorun"
require "mutant/minitest/coverage"
require "dcb_event_store"
