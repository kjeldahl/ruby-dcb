require "zlib"

module DcbEventStore
  class PostgresStore
    # Derives the advisory locks an append must hold from the events it writes
    # and its optional AppendCondition. Pure: a function of the two alone.
    #
    # The invariant is that any writer touching a tag serializes against any
    # condition naming that tag, whichever side is conditional. So every
    # append locks one key per distinct tag (a stable crc32 of the tag) across
    # both the tags its events carry and the tags its condition names, sorted
    # so every caller acquires in the same order and cannot deadlock. Tags an
    # event carries beyond what its condition names cost a lock each and
    # nothing else.
    #
    # A condition that constrains no tag (an item with only event types, or
    # Query.all) can match any event, so it takes the global key exclusively;
    # every other append takes the global key shared, which blocks such a
    # condition without serializing the tagged appends among themselves.
    module LockKeys
      # Key every append takes, shared by default, exclusive when the
      # condition can match events of any tag.
      APPEND_LOCK_KEY = 0

      # global: :shared or :exclusive, the mode for APPEND_LOCK_KEY.
      # tags: sorted keys taken exclusively after it.
      Locks = Data.define(:global, :tags)

      def self.for(events, condition)
        tags = tag_keys(events, condition)
        # A tag hashing to the global key is folded into it: taking that key
        # shared and then exclusive in one transaction would deadlock two such
        # appends against each other.
        exclusive = !tags.delete(APPEND_LOCK_KEY).nil? || global_exclusive?(condition)
        Locks.new(global: exclusive ? :exclusive : :shared, tags: tags)
      end

      # crc32 of every distinct tag the events carry or the condition names.
      # Zlib.crc32 returns a non-negative 32-bit integer, which fits a bigint
      # advisory-lock key directly.
      def self.tag_keys(events, condition)
        tags = events.flat_map(&:tags)
        tags += condition.fail_if_events_match.items.flat_map(&:tags) if condition
        tags.map { |tag| Zlib.crc32(tag) }.uniq.sort
      end

      def self.global_exclusive?(condition)
        return false unless condition

        query = condition.fail_if_events_match
        query.match_all? || query.items.any? { |item| item.tags.empty? }
      end
    end
  end
end
