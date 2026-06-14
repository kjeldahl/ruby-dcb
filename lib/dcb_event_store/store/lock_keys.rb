require "zlib"

module DcbEventStore
  class Store
    # Derives the set of advisory-lock keys an append must hold, from its
    # optional AppendCondition. Pure: a function of the condition alone.
    #
    # Unconditional appends (and conditions that constrain no tags) serialize on
    # a single global key so they cannot race the consistency check. Conditions
    # scoped to tags lock one key per distinct tag (a stable crc32 of the tag),
    # sorted to give every caller the same acquisition order and avoid deadlock.
    module LockKeys
      # Lock key used to serialize appends that are not scoped to specific tags.
      APPEND_LOCK_KEY = 0

      def self.for(condition)
        return [APPEND_LOCK_KEY] unless condition

        tags = condition.fail_if_events_match.items.flat_map(&:tags).uniq
        return [APPEND_LOCK_KEY] if tags.empty?

        # Zlib.crc32 returns a non-negative 32-bit integer, which fits a bigint
        # advisory-lock key directly. Sorted so every caller acquires keys in the
        # same order and concurrent appends cannot deadlock.
        tags.map { |tag| Zlib.crc32(tag) }.sort
      end
    end
  end
end
