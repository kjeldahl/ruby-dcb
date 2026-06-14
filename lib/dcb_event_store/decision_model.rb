module DcbEventStore
  module DecisionModel
    Result = Data.define(:states, :append_condition)

    def self.build(store, **projections)
      DcbEventStore.instrumentation.instrument("decision_model.dcb", projections: projections.keys) do |payload|
        combined_query = Query.new(projections.values.flat_map { |p| p.query.items })
        events = store.read(combined_query).to_a

        criteria = compile_criteria(projections)
        events_by_projection, max_position = partition_events(events, projections, criteria)
        states = projections.to_h { |name, proj| [name, proj.fold(events_by_projection[name])] }

        payload[:event_count] = events.size
        payload[:last_position] = max_position

        condition = AppendCondition.new(fail_if_events_match: combined_query, after: max_position)
        Result.new(states: states, append_condition: condition)
      end
    end

    def self.compile_criteria(projections)
      projections.transform_values do |projection|
        projection.query.items.map do |item|
          { event_types: item.event_types, tags: item.tags.to_set }
        end
      end
    end

    def self.partition_events(events, projections, criteria)
      events_by_projection = Hash.new { |h, k| h[k] = [] }

      events.each do |event|
        projections.each_key do |name|
          events_by_projection[name] << event if matches_any_item?(criteria.fetch(name), event)
        end
      end

      # store reads return events in ascending sequence order, so the last
      # event carries the highest position (nil when there are none).
      max_position = events.last&.sequence_position
      [events_by_projection, max_position]
    end

    def self.matches_any_item?(criteria, event)
      criteria.any? do |c|
        type_match = c.fetch(:event_types).empty? || c.fetch(:event_types).include?(event.type)
        tag_match = c.fetch(:tags).subset?(event.tags.to_set)
        type_match && tag_match
      end
    end

    private_class_method :compile_criteria, :partition_events, :matches_any_item?
  end
end
