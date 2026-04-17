module DcbEventStore
  module DecisionModel
    Result = Data.define(:states, :append_condition)

    def self.build(store, **projections)
      combined_items = projections.values.flat_map { |p| p.query.items }
      combined_query = Query.new(combined_items)

      events = store.read(combined_query).to_a

      # Pre-compute projection criteria for fast O(1) matching
      projection_criteria = {}
      projections.each do |name, projection|
        projection_criteria[name] = projection.query.items.map do |item|
          {
            event_types: item.event_types.empty? ? nil : item.event_types.to_set,
            tags: item.tags.to_set
          }
        end
      end

      # Single-pass: collect events per projection and compute max_position
      events_by_projection = Hash.new { |h, k| h[k] = [] }
      max_position = nil

      events.each do |event|
        pos = event.sequence_position
        max_position = pos if max_position.nil? || pos > max_position

        projections.each do |name, _projection|
          if matches_any_item?(projection_criteria[name], event)
            events_by_projection[name] << event
          end
        end
      end

      states = {}
      projections.each do |name, projection|
        states[name] = projection.fold(events_by_projection[name])
      end

      condition = AppendCondition.new(
        fail_if_events_match: combined_query,
        after: max_position
      )

      Result.new(states: states, append_condition: condition)
    end

    def self.matches_any_item?(criteria, event)
      criteria.any? do |c|
        type_match = c[:event_types].nil? || c[:event_types].include?(event.type)
        tag_match = c[:tags].subset?(event.tags.to_set)
        type_match && tag_match
      end
    end

    private_class_method :matches_any_item?
  end
end
