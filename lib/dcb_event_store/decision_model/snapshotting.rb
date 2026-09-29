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
      def self.load(snapshots, projections, namespace)
        return {} unless snapshots

        keys = projections.filter_map do |name, proj|
          [name, proj.snapshot.key(proj.query, namespace: namespace)] if proj.snapshot
        end
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

      # Writes the snapshots that are due and settled, and returns how many.
      # Each is written at the position its projection's read covered, and
      # each write is one "snapshot.dcb" event (operation: :write) naming the
      # projection, the key, the position and how many events were folded
      # on top of the previous snapshot.
      def self.store(snapshots, projections, folded, namespace, event_store)
        due = projections.select do |name, proj|
          due?(proj.snapshot, folded.entries[name], folded.positions.fetch(name)) &&
            settled?(event_store, proj, folded, name)
        end
        due.each do |name, proj|
          position = folded.positions.fetch(name)
          payload = identity(snapshots).merge(operation: :write, projection: name,
                                              key: proj.snapshot.key(proj.query, namespace: namespace),
                                              position: position,
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
        { store: snapshots.class.name, namespace: namespace_of(snapshots).name }
      end

      # The Namespace of a store or snapshot store; the default one when it
      # has no #namespace, or answers with a bare name (or nil).
      def self.namespace_of(store)
        store.respond_to?(:namespace) ? Namespace.wrap(store.namespace) : Namespace::DEFAULT
      end

      # A snapshot is due when the projection has none yet (and its read
      # covered anything at all), or when the position its read covered is
      # at least +every+ ahead of the one it holds.
      def self.due?(snapshot, entry, position)
        return false unless snapshot && position
        return true if entry.nil?

        position - entry.position >= snapshot.every
      end

      # Whether the events the projection folded are, for good, every event
      # matching its query from its snapshot up to the position the new one
      # would be written at. A read only vouches for what was committed when
      # it ran: on PostgreSQL an event below that position can still be in
      # flight, and a snapshot written past it would never fold it (issue
      # #55). The event store checks (#settled?); a store without that check
      # is taken at its read. Not settled: no write, a later build retries.
      def self.settled?(event_store, proj, folded, name)
        return true unless event_store.respond_to?(:settled?)

        events = folded.events_by_projection.fetch(name)
        position = folded.positions.fetch(name)
        return false if events.any? { |event| event.sequence_position > position }

        event_store.settled?(proj.query, after: folded.entries[name]&.position, through: position,
                                         count: events.size)
      end

      private_class_method :entries_from, :identity, :due?, :settled?
    end
  end
end
