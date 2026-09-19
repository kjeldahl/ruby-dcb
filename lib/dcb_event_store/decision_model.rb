module DcbEventStore
  module DecisionModel
    Result = Data.define(:states, :append_condition)
    EVENT = "decision_model.dcb".freeze

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
    # holds.
    #
    # The store's last position is taken *before* the reads, so every event
    # up to it was covered by them and the condition can guard up to the log
    # head rather than up to the last matching event. Snapshots are written
    # there too, once they have fallen +every+ positions behind the head (or
    # did not exist yet), so the catch-up read after a snapshot stays short
    # however quiet the entity is; the states they hold are exactly the
    # states this build returned.
    def self.build(store, snapshots: nil, **projections)
      DcbEventStore.instrumentation.instrument(EVENT, projections: projections.keys) do |payload|
        head = store.last_position if snapshots
        entries = Snapshotting.load(snapshots, projections)
        events = read_events(store, projections, entries)
        folded = fold(projections, events, entries, head)

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
    # after the group's position; the results are merged into one stream in
    # ascending sequence order. An event selected by two groups' queries is
    # read twice and kept once.
    def self.read_events(store, projections, entries)
      groups = projections.group_by { |name, _proj| entries[name]&.position }
      # No snapshots at all (including no projections: the union is Query.all,
      # so the condition guards the whole log): one plain read.
      return read_group(store, projections, nil).to_a if groups.empty? || groups.keys == [nil]

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

    def self.fold(projections, events, entries, head)
      criteria = compile_criteria(projections)
      events_by_projection, max_position = partition_events(events, projections, criteria, entries, head)
      states = projections.to_h do |name, proj|
        entry = entries[name]
        state = entry ? proj.fold(events_by_projection[name], from: entry.state) : proj.fold(events_by_projection[name])
        [name, state]
      end
      Folded.new(entries: entries, events_by_projection: events_by_projection, states: states,
                 max_position: max_position)
    end

    def self.compile_criteria(projections)
      projections.transform_values do |projection|
        projection.query.items.map do |item|
          { event_types: item.event_types, tags: item.tags.to_set }
        end
      end
    end

    def self.partition_events(events, projections, criteria, entries, head)
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
      # event carries the highest position; the log head read before the
      # reads, or a snapshot ahead of every event read, pins the position
      # instead. nil only when there is none of them.
      max_position = [head, events.last&.sequence_position, *entries.values.map(&:position)].compact.max
      [events_by_projection, max_position]
    end

    def self.matches_any_item?(criteria, event, tags)
      criteria.any? do |c|
        type_match = c.fetch(:event_types).empty? || c.fetch(:event_types).include?(event.type)
        tag_match = c.fetch(:tags).subset?(tags)
        type_match && tag_match
      end
    end

    private_class_method :read_events, :read_group, :combined, :fold, :compile_criteria, :partition_events,
                         :matches_any_item?
  end
end

require_relative "decision_model/snapshotting"
