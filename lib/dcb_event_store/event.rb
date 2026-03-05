require "securerandom"

module DcbEventStore
  Event = Data.define(:type, :data, :tags, :id) do
    def initialize(type:, data: {}, tags: [], id: SecureRandom.uuid)
      super(type: type.to_s, data: data, tags: tags.map(&:to_s).freeze, id: id)
    end
  end
end
