# Step 8: Projection + DecisionModel

## Goal
Implement the higher-level DSL for building decision models from composed projections.

## Files to Create
- `lib/dcb_event_store/projection.rb`
- `lib/dcb_event_store/decision_model.rb`

## Projection
```ruby
DcbEventStore::Projection.new(
  initial_state: 0,
  handlers: {
    "StudentSubscribedToCourse" => ->(state, event) { state + 1 }
  },
  query: Query.new([QueryItem.new(event_types: ["StudentSubscribedToCourse"], tags: ["course:c1"])])
)
```

- `#apply(state, event)` -- dispatches to handler by event.type, returns state unchanged if no handler
- `#fold(events)` -- reduces events starting from initial_state using apply
- `#event_types` -- extracts handled event types from handlers keys
- `#query` -- the Query used to fetch relevant events

## DecisionModel
`DecisionModel.build(store, **projections)` where projections is `name: Projection` pairs.

1. Merge all projection queries into one combined Query (OR all QueryItems)
2. Read events from store using combined query (materializes the enumerator to array)
3. For each projection, filter events to those matching its own query, then fold
4. Track max `sequence_position` across all read events
5. Return a result object with:
   - `states` -- Hash of `{ name => folded_state }`
   - `append_condition` -- `AppendCondition.new(fail_if_events_match: combined_query, after: max_position)`

### Edge Cases
- No events read: `after` is nil (condition checks all events)
- Projection with no matching events: returns initial_state

## Done When
- Projection folds events correctly with handler dispatch
- Projection ignores events with no matching handler
- DecisionModel composes multiple projections, reads once, returns correct states
- DecisionModel derives correct append_condition (combined query + max position)
- DecisionModel works with empty store (states are initial, after is nil)
