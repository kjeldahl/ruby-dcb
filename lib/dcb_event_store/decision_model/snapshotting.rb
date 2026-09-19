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

        payload = { store: snapshots.class.name, operation: :load, projections: keys.map(&:first),
                    requested: keys.size }
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

      # Writes the snapshots that are due and returns how many. Each write is
      # one "snapshot.dcb" event (operation: :write) naming the projection,
      # the key, the position and how many events were folded on top of the
      # previous snapshot.
      def self.store(snapshots, projections, folded)
        return 0 unless folded.max_position

        projections.count do |name, proj|
          folded_count = folded.events_by_projection[name].size
          next false unless due?(proj.snapshot, folded.entries[name], folded_count, folded.max_position)

          payload = { store: snapshots.class.name, operation: :write, projection: name,
                      key: proj.snapshot.key(proj.query), position: folded.max_position, folded_count: folded_count }
          DcbEventStore.instrumentation.instrument(StoreInstrumentation::SNAPSHOT_EVENT, payload) do
            state = proj.snapshot.dump(folded.states.fetch(name))
            snapshots.store(payload[:key], position: folded.max_position, state: state)
          end
          true
        end
      end

      # A snapshot is due when the projection has none yet, or when this build
      # folded at least +every+ events on top of it and there is a newer
      # position to record.
      def self.due?(snapshot, entry, folded_count, max_position)
        return false unless snapshot
        return true if entry.nil?

        folded_count >= snapshot.every && entry.position < max_position
      end

      private_class_method :entries_from, :due?
    end
  end
end
