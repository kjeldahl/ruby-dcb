module DcbEventStore
  module Web
    # Pure interpretation of the list query params. Given the decoded
    # query pairs (Array of [key, value]), it derives the namespace ("ns"),
    # paging (page/per_page/offset), the selected type and the accumulated tag
    # filter, then the Query, plus the snapshot key filter ("q"). Repeated
    # "tag" params AND together. No IO - fast
    # to unit and mutation test, so the Router that uses it stays thin glue.
    class ListParams
      DEFAULT_PER_PAGE = 50
      MAX_PER_PAGE = 200

      def initialize(pairs)
        @pairs = pairs
      end

      # The namespace asked for by "ns" (nil is the default namespace). Without
      # one, the default when +available+ (the names the browser can serve)
      # has it, else the first of them.
      def namespace(available)
        requested = last("ns")
        return requested unless requested.empty?

        available.first unless available.include?(nil)
      end

      # Substring the snapshot keys must contain.
      def match
        last("q")
      end

      # The snapshot key a detail page asks for.
      def key
        last("key")
      end

      def selected_type
        last("type")
      end

      def tags
        @pairs.filter_map { |k, v| v if k == "tag" }.reject(&:empty?).uniq
      end

      def per_page
        n = last("per_page").to_i
        return DEFAULT_PER_PAGE unless n.positive?

        [n, MAX_PER_PAGE].min
      end

      def page
        [last("page").to_i, 1].max
      end

      def offset
        (page - 1) * per_page
      end

      def query
        types = [selected_type].reject(&:empty?)
        return Query.all if types.empty? && tags.empty?

        Query.new(QueryItem.new(event_types: types, tags: tags))
      end

      private

      # The last value for +key+ (last-wins for single-valued params), or "".
      def last(key)
        @pairs.reverse.find { |k, _| k == key }&.last.to_s
      end
    end
  end
end
