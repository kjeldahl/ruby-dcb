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

### Baseline (25ccd01)
- DecisionModel.build with 5 projections takes ~150ms for 50k events
- Each projection called `events.select { |e| ... }` which iterated all events
- Total iterations = events × projections = 250k for 50k events and 5 projections
- Bug: `max_position` computed from exhausted Enumerator = always nil for non-empty stores

### Optimization Applied
- **Single-pass processing**: Iterate events once, collect into per-projection buckets
- **Pre-compute projection criteria**: Convert event_types and tags to Sets for O(1) lookups
- **Fixed bug**: Properly compute max_position from collected events array

### Results
- DecisionModel.build improved from ~150ms to ~30ms for 50k events (5x speedup)
- All tests pass (105 runs, 190 assertions, 0 failures)

### Ideas for Further Optimization
1. **SQL-level optimization**: The SQL query is now the bottleneck (~27ms vs ~0.1ms for Ruby). Consider:
   - Simplifying query structure
   - Using prepared statements
   - Optimizing index usage
2. **Row parsing optimization**: `row_to_sequenced_event` does JSON parse, Time parse, and array parse for every row
3. **Stream events instead of loading into memory**: Avoid `.to_a` call, stream directly to projections

### Final Summary
- DecisionModel.build optimization achieved **5x speedup** on Ruby processing
- Before: ~150ms total (dominated by Ruby multi-pass iteration)
- After: ~27ms total (SQL query is now the bottleneck, not Ruby)
- All tests pass (105 runs, 190 assertions, 0 failures)
- API compatibility maintained (no changes to public interface)