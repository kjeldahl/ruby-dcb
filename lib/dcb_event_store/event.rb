require "securerandom"
require_relative "validation"

module DcbEventStore
  Event = Data.define(:type, :data, :tags, :id, :causation_id, :correlation_id) do
    # Default validation is disabled for backward compatibility
    # Set DcbEventStore.validate_events = true to enable validation globally
    def initialize(type:, data: {}, tags: [], id: SecureRandom.uuid, causation_id: nil, correlation_id: nil,
                   validate: nil)
      # Use global setting if validate parameter is not explicitly provided
      should_validate = validate.nil? ? DcbEventStore.validate_events : validate

      Validation.validate_event(type: type, data: data, tags: tags) if should_validate

      super(
        type: type.to_s,
        data: data.nil? ? {} : data,
        tags: tags.map(&:to_s).freeze,
        id: id,
        causation_id: causation_id,
        correlation_id: correlation_id
      )
    end
  end
end
