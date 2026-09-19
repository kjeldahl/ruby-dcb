require "json"

module DcbEventStore
  # Opt-in snapshot configuration for a Projection.
  #
  # A snapshot is the projection's state folded through every matching event
  # up to a sequence position. DecisionModel.build loads it, reads only the
  # events after that position and folds them on top, so the cost of a
  # decision stops growing with the length of the projection's history.
  #
  # The snapshot key combines +name+, +version+ and the projection's query
  # (its Query#fingerprint, which carries the entity tags), so one
  # configuration serves every instance of a projection and each entity gets
  # its own snapshot. Bump
  # +version+ whenever the handlers change: the old snapshots are then simply
  # never read again.
  #
  # +every+ is the write policy: a fresh snapshot is stored once the log head
  # has moved at least that many positions past the last one (1 = whenever
  # anything at all was appended since), so the catch-up read after it never
  # has to look past more than +every+ events, matching or not.
  #
  # +dump+ / +load+ convert the state to and from the value the snapshot
  # store persists. The default keeps JSON-compatible states (numbers,
  # strings, booleans, arrays, symbol-keyed hashes) intact through the SQL
  # stores; states built from other objects (Struct, Data, Set, Time) need
  # their own pair.
  class Snapshot
    Entry = Data.define(:position, :state)

    attr_reader :name, :version, :every

    def initialize(name:, version: 1, every: 1, dump: nil, load: nil)
      raise ArgumentError, "every must be >= 1" unless every >= 1

      @name = name.to_s
      @version = version
      @every = every
      @dump = dump || ->(state) { state }
      @load = load || ->(state) { state }
    end

    def key(query)
      "#{@name}/v#{@version}/#{query.fingerprint}"
    end

    def dump(state) = @dump.call(state)
    def load(state) = @load.call(state)
  end
end
