require "digest"
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
  # its own snapshot. A fingerprint longer than a SHA-256 hex digest is
  # replaced by that digest, so a key never grows with the query beyond
  # "name/vN/" plus 64 characters; short ones stay readable.
  #
  # Nothing can tell that a handler changed, so invalidation is explicit:
  # +version+ has no default, and bumping it makes the old snapshots
  # unreachable (a store's #purge removes them). For a change that touches
  # every projection at once, DcbEventStore::Snapshots.epoch prefixes every
  # key instead ("<epoch>/name/vN/…"); set it once at boot, e.g. to the
  # release, and #purge_other_epochs drops what earlier epochs left.
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

    def initialize(name:, version:, every: 1, dump: nil, load: nil)
      raise ArgumentError, "every must be >= 1" unless every >= 1

      @name = name.to_s
      @version = version
      @every = every
      @dump = dump || ->(state) { state }
      @load = load || ->(state) { state }
    end

    # Longest fingerprint kept verbatim: the length of a SHA-256 hex digest.
    DIGEST_LENGTH = 64

    # "<epoch>/name/vN/" without the epoch part when none is set, or without
    # the version part when +version+ is nil: what every key of +name+ (at
    # +version+) starts with, which is what the stores' #purge matches on.
    def self.key_prefix(name, version)
      parts = [Snapshots.epoch, name]
      parts << "v#{version}" if version
      "#{parts.compact.join('/')}/"
    end

    # "<epoch>/": what every key of the current epoch starts with. Nil when
    # no epoch is set, since then keys carry no epoch part at all.
    def self.epoch_prefix
      Snapshots.epoch && "#{Snapshots.epoch}/"
    end

    def key(query)
      "#{self.class.key_prefix(@name, @version)}#{key_part(query.fingerprint)}"
    end

    def key_part(fingerprint)
      return fingerprint if fingerprint.length <= DIGEST_LENGTH

      Digest::SHA256.hexdigest(fingerprint)
    end
    private :key_part

    def dump(state) = @dump.call(state)
    def load(state) = @load.call(state)
  end
end
