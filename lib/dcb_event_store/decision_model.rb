module DcbEventStore
  module DecisionModel
    Result = Data.define(:states, :append_condition)

    # What one build folded: the snapshot entries it started from (by
    # projection name), the events each projection folded, the resulting
    # states and the position the append condition guards.
    Folded = Data.define(:entries, :events_by_projection, :states, :max_position)

    # Reads the union of the projections' queries, folds each projection
    # over its share of the events and returns the states together with the
    # AppendCondition guarding them.
    #
    # With a +snapshots+ store, every projection configured with a Snapshot
    # starts from its stored state instead of the initial one and only needs
    # the events after its snapshot position. Projections sharing a position
    # share one read (a build writes all its snapshots at the same position,
    # so this is the common case); projections without a snapshot share a read
    # from the start of the log. The reads are merged into one ascending
    # stream before partitioning, and a projection skips whatever it already
    # holds. Afterwards the snapshots that fell behind by at least their
    # +every+ events (or did not exist yet) are written at the position the
    # condition guards, so the states they hold are exactly the states this
    # build returned.
    def self.build(store, snapshots: nil, **projections)
      DcbEventStore.instrumentation.instrument("decision_model.dcb", projections: projections.keys) do |payload|
        entries = load_snapshots(snapshots, projections)
        events = read_events(store, projections, entries)
        folded = fold(projections, events, entries)

        payload[:event_count] = events.size
        payload[:last_position] = folded.max_position
        if snapshots
          payload[:snapshots_loaded] = entries.size
          payload[:snapshots_written] = store_snapshots(snapshots, projections, folded)
        end

        condition = AppendCondition.new(fail_if_events_match: combined(projections), after: folded.max_position)
        Result.new(states: folded.states, append_condition: condition)
      end
    end

    # name => Snapshot::Entry for every projection that has a snapshot
    # configured and stored; one round trip to the snapshot store.
    def self.load_snapshots(snapshots, projections)
      return {} unless snapshots

      keys = projections.filter_map { |name, proj| [name, proj.snapshot.key(proj.query)] if proj.snapshot }
      return {} if keys.empty?

      found = snapshots.fetch_many(keys.map(&:last))
      keys.filter_map do |name, key|
        entry = found[key]
        next unless entry

        [name, Snapshot::Entry.new(position: entry.position, state: projections.fetch(name).snapshot.load(entry.state))]
      end.to_h
    end

    # One read per distinct snapshot position (nil for the projections
    # without one), each over the union of that group's queries and starting
    # after the group's position; the results are merged into one stream in
    # ascending sequence order. An event selected by two groups' queries is
    # read twice and kept once.
    def self.read_events(store, projections, entries)
      groups = projections.group_by { |name, _proj| entries[name]&.position }
      return read_group(store, projections, nil).to_a if groups.keys == [nil]

      by_position = {}
      groups.each do |position, group|
        read_group(store, group.to_h, position).each { |event| by_position[event.sequence_position] ||= event }
      end
      by_position.values.sort_by!(&:sequence_position)
    end

    def self.read_group(store, projections, position)
      query = combined(projections)
      position ? store.read_from(query, after: position) : store.read(query)
    end

    def self.combined(projections)
      Query.new(projections.values.flat_map { |p| p.query.items })
    end

    def self.fold(projections, events, entries)
      criteria = compile_criteria(projections)
      events_by_projection, max_position = partition_events(events, projections, criteria, entries)
      states = projections.to_h do |name, proj|
        entry = entries[name]
        state = entry ? proj.fold(events_by_projection[name], from: entry.state) : proj.fold(events_by_projection[name])
        [name, state]
      end
      Folded.new(entries: entries, events_by_projection: events_by_projection, states: states,
                 max_position: max_position)
    end

    # Writes the snapshots that are due and returns how many.
    def self.store_snapshots(snapshots, projections, folded)
      return 0 unless folded.max_position

      projections.count do |name, proj|
        next false unless snapshot_due?(proj.snapshot, folded.entries[name], folded.events_by_projection[name].size,
                                        folded.max_position)

        state = proj.snapshot.dump(folded.states.fetch(name))
        snapshots.store(proj.snapshot.key(proj.query), position: folded.max_position, state: state)
        true
      end
    end

    # A snapshot is due when the projection has none yet, or when this build
    # folded at least +every+ events on top of it and there is a newer
    # position to record.
    def self.snapshot_due?(snapshot, entry, folded_count, max_position)
      return false unless snapshot
      return true if entry.nil?

      folded_count >= snapshot.every && entry.position < max_position
    end

    def self.compile_criteria(projections)
      projections.transform_values do |projection|
        projection.query.items.map do |item|
          { event_types: item.event_types, tags: item.tags.to_set }
        end
      end
    end

    def self.partition_events(events, projections, criteria, entries)
      events_by_projection = Hash.new { |h, k| h[k] = [] }

      events.each do |event|
        tags = event.tags.to_set
        projections.each_key do |name|
          # An event already folded into this projection's snapshot: its read
          # group started at another projection's (lower) position.
          next if entries[name] && event.sequence_position <= entries[name].position
          next unless matches_any_item?(criteria.fetch(name), event, tags)

          events_by_projection[name] << event
        end
      end

      # store reads return events in ascending sequence order, so the last
      # event carries the highest position; a snapshot ahead of every event
      # read (nothing new since it was taken) pins the position instead. nil
      # only when there are neither.
      max_position = [events.last&.sequence_position, *entries.values.map(&:position)].compact.max
      [events_by_projection, max_position]
    end

    def self.matches_any_item?(criteria, event, tags)
      criteria.any? do |c|
        type_match = c.fetch(:event_types).empty? || c.fetch(:event_types).include?(event.type)
        tag_match = c.fetch(:tags).subset?(tags)
        type_match && tag_match
      end
    end

    private_class_method :load_snapshots, :read_events, :read_group, :combined, :fold, :store_snapshots,
                         :snapshot_due?, :compile_criteria, :partition_events, :matches_any_item?
  end
end
