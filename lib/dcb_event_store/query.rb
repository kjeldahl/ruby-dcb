require "json"

module DcbEventStore
  QueryItem = Data.define(:event_types, :tags) do
    def initialize(event_types:, tags: [])
      super(
        event_types: Array(event_types).map(&:to_s).freeze,
        tags: Array(tags).map(&:to_s).freeze
      )
    end

    # Compact, space-free rendering for logs: "A,B" (types),
    # "A,B{t:1}" (types + tags), "{t:1}" (tags only), "any" (empty).
    def to_s
      types = event_types.join(",")
      types << "{#{tags.join(',')}}" unless tags.empty?
      types.empty? ? "any" : types
    end
    alias_method :inspect, :to_s
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

    # An unambiguous identity for caching, unlike #to_s: the items as a JSON
    # array of [event_types, tags] pairs, so a tag containing "," or "{"
    # cannot make two different queries read alike ("[]" for Query.all).
    def fingerprint
      JSON.generate(@items.map { |item| [item.event_types, item.tags] })
    end

    # "Query.all" when unbounded, else "Query[itemA|itemB]" with items
    # rendered by QueryItem#to_s and OR-joined by "|".
    def to_s
      return "Query.all" if match_all?

      "Query[#{@items.join('|')}]"
    end
    alias inspect to_s
  end
end
