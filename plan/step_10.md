# Step 10: Concurrency Tests

## Goal
Prove that the advisory lock mechanism correctly handles concurrent access. Multiple threads racing to append conflicting events must result in exactly one winner.

## Files to Create
- `test/concurrency/test_concurrent_append.rb`

## Dependencies
- `concurrent-ruby` gem (CyclicBarrier for thread synchronization)

## Test Cases

### Test 1: Exactly one wins
- N=20 threads, each with its own PG::Connection and Store
- All threads read the same state (no events yet)
- All build the same append condition (fail if any "SeatReserved" with tag "course:c1" exists)
- CyclicBarrier synchronizes all threads to call append simultaneously
- Assert: exactly 1 thread succeeds, N-1 raise ConditionNotMet
- Assert: exactly 1 "SeatReserved" event in the database

### Test 2: Non-conflicting appends all succeed
- N=10 threads, each appending with different tags (e.g., "course:c{i}")
- Each thread's condition only matches its own tag
- Assert: all N threads succeed
- Assert: N events in the database

### Test 3: Retry after conflict succeeds
- 2 threads race to append the same event
- Loser catches ConditionNotMet, re-reads state, rebuilds condition, retries
- Assert: both events eventually appended (2 events in DB)
- Assert: no data loss or corruption

### Test 4: Event count integrity under load
- N=50 threads, each attempting one append with a shared condition
- Assert: final event count in DB equals number of successful appends
- Assert: sequence_positions are unique and monotonically increasing

## Implementation Notes
- Each thread MUST create its own `PG::Connection` (pg connections are not thread-safe)
- Use `Concurrent::CyclicBarrier.new(n)` to align thread start times
- Collect results in `Concurrent::Array`
- Set reasonable timeout (10s) for thread joins
- Clean up connections in ensure blocks

## Done When
- All 4 concurrency tests pass reliably (run 3x to check for flakiness)
- `bundle exec rake` runs all tests (unit + integration + concurrency) green
- No deadlocks, no data corruption, no flaky failures
