module DcbEventStore
  module Snapshots
    # Process-local snapshot store: a Hash guarded by a Mutex.
    #
    # Nothing is serialized, so the cached state is the very object the fold
    # produced; a projection whose handlers mutate their state in place must
    # supply dump:/load: (Marshal is the general answer) or copy on load.
    # Shared by every store in the process and lost with it — a warm cache,
    # not a persistent one.
    class InMemorySnapshotStore
      def initialize
        @entries = {}
        @mutex = Mutex.new
      end

      def fetch(key)
        @mutex.synchronize { @entries[key] }
      end

      # key => Entry for the keys that have one.
      def fetch_many(keys)
        @mutex.synchronize { @entries.slice(*keys) }
      end

      # Keeps the newest position: a slower builder racing a faster one must
      # not roll the snapshot back.
      def store(key, position:, state:)
        @mutex.synchronize do
          current = @entries[key]
          next if current && current.position >= position

          @entries[key] = Snapshot::Entry.new(position: position, state: state)
        end
        nil
      end

      def delete(key)
        @mutex.synchronize { @entries.delete(key) }
        nil
      end

      def clear
        @mutex.synchronize { @entries.clear }
        nil
      end

      def size
        @mutex.synchronize { @entries.size }
      end
    end
  end
end
