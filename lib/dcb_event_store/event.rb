module DcbEventStore
  Event = Data.define(:type, :data, :tags) do
    def initialize(type:, data: {}, tags: [])
      super(type: type.to_s, data: data, tags: tags.map(&:to_s).freeze)
    end
  end
end
