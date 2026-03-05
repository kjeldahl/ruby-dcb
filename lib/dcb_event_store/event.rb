require "securerandom"

module DcbEventStore
  Event = Data.define(:type, :data, :tags, :id, :causation_id, :correlation_id) do
    def initialize(type:, data: {}, tags: [], id: SecureRandom.uuid, causation_id: nil, correlation_id: nil)
      super(
        type: type.to_s,
        data: data,
        tags: tags.map(&:to_s).freeze,
        id: id,
        causation_id: causation_id,
        correlation_id: correlation_id
      )
    end
  end
end
