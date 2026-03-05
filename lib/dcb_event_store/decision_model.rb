module DcbEventStore
  module DecisionModel
    Result = Data.define(:states, :append_condition)

    def self.build(store, **projections)
      combined_items = projections.values.flat_map { |p| p.query.items }
      combined_query = Query.new(combined_items)

      events = store.read(combined_query).to_a

      states = {}
      projections.each do |name, projection|
        relevant = events.select { |e| matches_projection?(projection, e) }
        states[name] = projection.fold(relevant)
      end

      max_position = events.map(&:sequence_position).max

      condition = AppendCondition.new(
        fail_if_events_match: combined_query,
        after: max_position
      )

      Result.new(states: states, append_condition: condition)
    end

    def self.matches_projection?(projection, event)
      projection.query.items.any? do |item|
        type_match = item.event_types.empty? || item.event_types.include?(event.type)
        tag_match = item.tags.empty? || item.tags.all? { |t| event.tags.include?(t) }
        type_match && tag_match
      end
    end

    private_class_method :matches_projection?
  end
end
