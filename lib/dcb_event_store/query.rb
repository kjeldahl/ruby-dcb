module DcbEventStore
  QueryItem = Data.define(:event_types, :tags) do
    def initialize(event_types:, tags: [])
      super(
        event_types: Array(event_types).map(&:to_s).freeze,
        tags: Array(tags).map(&:to_s).freeze
      )
    end
  end

  class Query
    attr_reader :items

    def initialize(items = nil)
      @items = Array(items).freeze
    end

    def self.all = new

    def match_all? = @items.empty?

    def ==(other)
      other.instance_of?(Query) && other.items == @items
    end
  end
end
