module DcbEventStore
  # Raised by append when some, but not all, of its events carry an id that
  # is already stored. Every id stored means a retry of an append that went
  # through, which returns the stored events instead; a partial overlap has
  # no such reading, so nothing is written. +ids+ are the ids already stored.
  class DuplicateEvent < StandardError
    attr_reader :ids

    def initialize(ids)
      @ids = ids
      super("event id(s) already stored: #{ids.join(', ')}")
    end
  end
end
