module DcbEventStore
  module DecisionModel
    Result = Data.define(:states, :append_condition)
    EVENT = "decision_model.dcb".freeze

    # One read group: the projections (by name) sharing a snapshot position
    # (+position+ nil for the ones without a snapshot), the events its read
    # returned, and how far it is known to have covered its queries:
    # the last event it read, or its position when it read nothing.
    Group = Data.define(:position, :names, :events) do
      def coverage = events.last&.sequence_position || position
    end

    # What one build folded: the snapshot entries it started from (by
    # projection name), the events each projection folded, the resulting
    # states, the position each projection's read covered (where its
    # snapshot may be written) and the highest of those, which the append
    # condition guards.
    Folded = Data.define(:entries, :events_by_projection, :states, :positions, :max_position)

    # Reads the union of the projections' queries, folds each projection
    # over its share of the events and returns the states together with the
    # AppendCondition guarding them.
    #
    # With a +snapshots+ store, every projection configured with a Snapshot
    # starts from its stored state instead of the initial one and only needs
    # the events after its snapshot position. Projections sharing a position
    # share one read (a build writes a group's snapshots at the same position,
    # so this is the common case); projections without a snapshot share a read
    # from the start of the log. The reads are merged into one ascending
    # stream before partitioning, and a projection skips whatever it already
    # holds.
    #
    # The reads happen one after another, so an event committed between two
    # of them would be missed by the earlier one. The store's last position
    # is taken *before* any read and every event past it is dropped: what
    # each read covered is then bounded by a position that predates all of
    # them. Within that bound a group is known to have covered its queries
    # up to the last event it read (matching events on a tag are committed
    # in order, which is what the append condition relies on too), so that
    # is where its snapshots are written and what the condition guards; the
    # log head itself is not, since on PostgreSQL it can lie past an
    # uncommitted append on the very tag being decided about.
    def self.build(store, snapshots: nil, **projections)
      DcbEventStore.instrumentation.instrument(EVENT, projections: projections.keys) do |payload|
        bound = store.last_position || 0 if snapshots
        entries = Snapshotting.load(snapshots, projections)
        groups = read_groups(store, projections, entries, bound)
        events = merge_reads(groups)
        folded = fold(projections, events, groups, entries)

        payload[:event_count] = events.size
        payload[:last_position] = folded.max_position
        if snapshots
          payload[:snapshots_loaded] = entries.size
          payload[:snapshots_written] = Snapshotting.store(snapshots, projections, folded)
        end

        condition = AppendCondition.new(fail_if_events_match: combined(projections), after: folded.max_position)
        Result.new(states: folded.states, append_condition: condition)
      end
    end

    # One read per distinct snapshot position (nil for the projections
    # without one), each over the union of that group's queries and starting
    # after the group's position. With +bound+ (the log head taken before
    # any read), events past it are left out.
    def self.read_groups(store, projections, entries, bound)
      # No projections: the union is Query.all, and the condition guards the
      # whole log, so the whole log is read.
      return [read_group(store, projections, nil, bound)] if projections.empty?

      projections.group_by { |name, _proj| entries[name]&.position }
                 .map { |position, group| read_group(store, group.to_h, position, bound) }
    end

    def self.read_group(store, projections, position, bound)
      query = combined(projections)
      events = position ? store.read_from(query, after: position) : store.read(query)
      events = events.take_while { |event| event.sequence_position <= bound } if bound
      Group.new(position: position, names: projections.keys, events: events.to_a)
    end

    # Merges the groups' ascending reads into one ascending stream, keeping
    # an event read by more than one of them once.
    def self.merge_reads(groups)
      by_position = {}
      groups.each { |group| group.events.each { |event| by_position[event.sequence_position] ||= event } }
      by_position.sort_by(&:first).map(&:last)
    end

    def self.combined(projections)
      Query.new(projections.values.flat_map { |p| p.query.items })
    end

    def self.fold(projections, events, groups, entries)
      criteria = compile_criteria(projections)
      events_by_projection = partition_events(events, projections, criteria, entries)
      states = projections.to_h do |name, proj|
        entry = entries[name]
        state = entry ? proj.fold(events_by_projection[name], from: entry.state) : proj.fold(events_by_projection[name])
        [name, state]
      end
      positions = groups.flat_map { |group| group.names.map { |name| [name, group.coverage] } }.to_h
      Folded.new(entries: entries, events_by_projection: events_by_projection, states: states,
                 positions: positions, max_position: groups.filter_map(&:coverage).max)
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
          entry = entries[name]
          next if entry && event.sequence_position <= entry.position
          next unless matches_any_item?(criteria.fetch(name), event, tags)

          events_by_projection[name] << event
        end
      end

      events_by_projection
    end

    def self.matches_any_item?(criteria, event, tags)
      criteria.any? do |c|
        type_match = c.fetch(:event_types).empty? || c.fetch(:event_types).include?(event.type)
        tag_match = c.fetch(:tags).subset?(tags)
        type_match && tag_match
      end
    end

    private_class_method :read_groups, :read_group, :merge_reads, :combined, :fold, :compile_criteria,
                         :partition_events, :matches_any_item?
  end
end

require_relative "decision_model/snapshotting"
