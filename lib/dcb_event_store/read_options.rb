module DcbEventStore
  # How a read walks the matching stream: forwards (oldest first) from
  # +after+, or, with +backwards+, newest first from +before+ -- both bounds
  # exclusive, nil meaning the start (or end) of the log -- yielding at most
  # +limit+ events (nil = all of them).
  #
  # Each direction takes its own bound, so a read never mixes them up:
  # after: with backwards: true, or before: without it, is an ArgumentError.
  ReadOptions = Data.define(:after, :before, :backwards, :limit) do
    def initialize(after: nil, before: nil, backwards: false, limit: nil)
      check_direction(after, before, backwards)
      check_limit(limit)
      super
    end

    # The SQL ordering of the read's direction.
    def order
      backwards ? :desc : :asc
    end

    # The number of rows to ask for next: +batch_size+, or fewer when the
    # limit is closer.
    def page_size(batch_size)
      limit ? [limit, batch_size].min : batch_size
    end

    # The options for the rest of the read, once a page of +count+ rows
    # ending at +position+ was yielded: the bound moved past it and the
    # limit reduced by it. nil when the limit is used up.
    def after_page(position, count)
      return nil if limit == count

      rest = limit && (limit - count)
      backwards ? with(before: position, limit: rest) : with(after: position, limit: rest)
    end

    private

    def check_direction(after, before, backwards)
      unless [true, false].include?(backwards)
        raise ArgumentError, "backwards must be true or false, got #{backwards.inspect}"
      end

      raise ArgumentError, "after: reads forwards; a backwards read takes before:" if backwards && after
      raise ArgumentError, "before: bounds a backwards read; pass backwards: true" if before && !backwards
    end

    def check_limit(limit)
      return if limit.nil? || (limit.is_a?(Integer) && limit.positive?)

      raise ArgumentError, "limit must be a positive Integer, got #{limit.inspect}"
    end
  end
end
