# Step 9: Projection + DecisionModel Tests

## Goal
Test projection folding and decision model composition, including a full end-to-end scenario.

## Files to Create
- `test/unit/test_projection.rb`
- `test/integration/test_decision_model.rb`

## Test Cases

### test_projection.rb (unit, no DB)
- Fold with no events returns initial_state
- Fold applies matching handler and returns new state
- Fold ignores events with no matching handler
- Fold processes multiple events in sequence
- apply returns state unchanged for unknown event type
- Handlers are pure (same events -> same state)

### test_decision_model.rb (integration, needs DB)
- Build with single projection returns correct state
- Build with multiple projections returns all states
- Combined query is the OR of all projection queries
- append_condition.after equals max sequence_position of read events
- append_condition.after is nil when store is empty
- **End-to-end: course subscription scenario**
  - Define a course (append CourseDefined event)
  - Build decision model with capacity + subscription count projections
  - Subscribe a student using the returned condition
  - Build decision model again -- see updated counts
  - Attempt to exceed capacity -- ConditionNotMet after another student subscribes concurrently

## Done When
- All unit + integration tests pass via `bundle exec rake`
- The course subscription scenario demonstrates the full read-decide-append-fail cycle
