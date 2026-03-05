# Step 7: Integration Tests (Store)

## Goal
Test Store#read and Store#append against a real PostgreSQL database.

## Files to Create
- `test/support/database.rb` -- helper that:
  - Connects to `dcb_event_store_test` database (env var `DATABASE_URL` or default localhost)
  - Calls `Schema.create!(conn)` on setup
  - Truncates `events` table before each test
  - Provides `conn` accessor
- `test/integration/test_store_read.rb`
- `test/integration/test_store_append.rb`

## Test Cases

### test_store_read.rb
- Read from empty store returns empty enumerator
- Read with Query.all returns all events
- Read filters by single event type
- Read filters by single tag (contains semantics)
- Read filters by multiple tags (AND -- must contain ALL)
- Read filters by event type + tags combined
- Read with multiple QueryItems (OR semantics) -- event matching either item is returned
- Read returns events ordered by sequence_position ASC
- SequencedEvent fields have correct Ruby types (Integer, Hash, Array, Time)

### test_store_append.rb
- Append without condition inserts events
- Append returns SequencedEvents with assigned positions
- Append multiple events in one call -- all get sequential positions
- Append with condition succeeds when no conflicting events
- Append with condition raises ConditionNotMet when matching events exist
- Append with condition + after: ignores events at or before `after` position
- Append with condition + nil after: checks ALL events in store
- Failed append leaves no events in table (transaction rolled back)
- ConditionNotMet is rescuable

## Prerequisites
- PostgreSQL running locally
- Database `dcb_event_store_test` exists (`createdb dcb_event_store_test`)

## Done When
- `bundle exec rake` passes all unit + integration tests
- Tests are isolated (each test starts with empty events table)
- No test depends on another test's data
