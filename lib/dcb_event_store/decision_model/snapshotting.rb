module DcbEventStore
  module DecisionModel
    # The snapshot half of DecisionModel.build: loading the entries a build
    # starts from and writing back the ones that are due, each side published
    # as "snapshot.dcb" events.
    module Snapshotting
      # name => Snapshot::Entry for every projection that has a snapshot
      # configured and stored; one round trip to the snapshot store, published
      # as one "snapshot.dcb" event (operation: :load) with how many snapshots
      # were asked for and how many existed.
      def self.load(snapshots, projections)
        return {} unless snapshots

        keys = projections.filter_map { |name, proj| [name, proj.snapshot.key(proj.query)] if proj.snapshot }
        return {} if keys.empty?

        payload = identity(snapshots).merge(operation: :load, projections: keys.map(&:first),
                                            requested: keys.size)
        DcbEventStore.instrumentation.instrument(StoreInstrumentation::SNAPSHOT_EVENT, payload) do |inner|
          found = snapshots.fetch_many(keys.map(&:last))
          inner[:loaded] = found.size
          entries_from(found, keys, projections)
        end
      end

      def self.entries_from(found, keys, projections)
        keys.filter_map do |name, key|
          entry = found[key]
          next unless entry

          state = projections.fetch(name).snapshot.load(entry.state)
          [name, Snapshot::Entry.new(position: entry.position, state: state)]
        end.to_h
      end

      # Writes the snapshots that are due and returns how many. Each is
      # written at the position its projection's read covered, and each
      # write is one "snapshot.dcb" event (operation: :write) naming the
      # projection, the key, the position and how many events were folded
      # on top of the previous snapshot.
      def self.store(snapshots, projections, folded)
        due = projections.select do |name, proj|
          due?(proj.snapshot, folded.entries[name], folded.positions.fetch(name))
        end
        due.each do |name, proj|
          position = folded.positions.fetch(name)
          payload = identity(snapshots).merge(operation: :write, projection: name,
                                              key: proj.snapshot.key(proj.query), position: position,
                                              folded_count: folded.events_by_projection.fetch(name).size)
          DcbEventStore.instrumentation.instrument(StoreInstrumentation::SNAPSHOT_EVENT, payload) do
            state = proj.snapshot.dump(folded.states.fetch(name))
            snapshots.store(payload.fetch(:key), position: position, state: state)
          end
        end
        due.size
      end

      # The store: and namespace: a snapshot.dcb payload starts with: the
      # snapshot store's class and its namespace name (nil in the default
      # namespace, and for a snapshot store that has no notion of one).
      def self.identity(snapshots)
        namespace = snapshots.namespace.name if snapshots.respond_to?(:namespace)
        { store: snapshots.class.name, namespace: namespace }
      end

      # A snapshot is due when the projection has none yet (and its read
      # covered anything at all), or when the position its read covered is
      # at least +every+ ahead of the one it holds.
      def self.due?(snapshot, entry, position)
        return false unless snapshot && position
        return true if entry.nil?

        position - entry.position >= snapshot.every
      end

      private_class_method :entries_from, :identity, :due?
    end
  end
end
