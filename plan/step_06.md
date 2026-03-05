# Step 6: Unit Tests

## Goal
Test all value objects in isolation (no database needed).

## Files to Create
- `test/test_helper.rb` -- require minitest/autorun, require dcb_event_store
- `test/unit/test_event.rb`
- `test/unit/test_query.rb`

## Test Cases

### test_event.rb
- Creates Event with type, data, tags
- Type is coerced to string
- Data defaults to empty hash
- Tags default to empty array
- Tags are frozen (immutable)
- Event is frozen
- Two Events with same attributes are equal (structural equality)

### test_query.rb
- QueryItem creation with event_types and tags
- QueryItem event_types coerced to string array
- Query with multiple items stores them
- Query.all returns a Query where match_all? is true
- Regular Query has match_all? == false
- AppendCondition creation with query and after
- AppendCondition after defaults to nil

## Done When
- `bundle exec rake` runs all unit tests
- All tests pass
- No database connection needed for these tests
