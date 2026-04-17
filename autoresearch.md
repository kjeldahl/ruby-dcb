# Autoresearch: Optimize DecisionModel.build - single-pass event processing

## Objective
The `DecisionModel.build` method currently iterates through all events **once per projection** when computing states. With 5 projections and 50,000 events, this results in 250,000 iterations. Optimize to single-pass processing.

## Metrics
- **Primary**: decision_model_ms (ms, lower is better) — time to run DecisionModel.build with 5 projections
- **Secondary**: decision_model_build_time_ms (ms, lower is better) — raw timing

## How to Run
`./autoresearch.sh` — outputs `METRIC decision_model_ms=value` lines.

## Files in Scope
- `lib/dcb_event_store/decision_model.rb` — contains DecisionModel.build which is the bottleneck
- `lib/dcb_event_store/projection.rb` — Projection class used in DecisionModel
- `lib/dcb_event_store/query.rb` — Query and QueryItem data structures

## Off Limits
- Do not change the public API of DecisionModel, Projection, or Query
- Do not change the test suite (tests must pass)
- Do not add new dependencies

## Constraints
- All tests must pass (`bundle exec rake`)
- No new gems or dependencies
- API compatibility must be maintained

## What's Been Tried

### Baseline
- DecisionModel.build with 5 projections takes ~150ms for 50k events
- Each projection calls `events.select { |e| matches_projection?(projection, e) }` which iterates all events
- Total iterations = events × projections = 250k for 50k events and 5 projections

### Current Implementation Issue
```ruby
def self.build(store, **projections)
  combined_items = projections.values.flat_map { |p| p.query.items }
  combined_query = Query.new(combined_items)
  
  events = store.read(combined_query)  # Returns Enumerator
  
  states = {}
  projections.each do |name, projection|
    # BUG: This calls store.read again, creating a new Enumerator!
    relevant = events.select { |e| matches_projection?(projection, e) }
    states[name] = projection.fold(relevant)
  end
  
  max_position = events.map(&:sequence_position).max
  # ...
end
```

Wait, actually looking at this more carefully - there's a subtle issue. `store.read(combined_query)` is called ONCE, returning an Enumerator. Then `events.select` consumes it and returns an array. So subsequent iterations use the array. But the `events.map(&:sequence_position)` call happens AFTER all selects, so it operates on the (now exhausted) Enumerator.

Actually, this might be a bug - the `max_position` computation might be operating on an empty Enumerator! Let me verify this.

### Optimization Ideas
1. **Single-pass with grouping**: Build a map of event_type -> projection indices, then iterate once
2. **Pre-compute match sets**: Use Sets for O(1) tag/type lookups instead of Array operations
3. **Batch processing**: Process all projections in one event iteration