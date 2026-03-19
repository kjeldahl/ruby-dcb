# Step 12: Idempotent Writes

## Goal
Appending an event with the same `event_id` twice is silently ignored, not an error. Enables safe retries.

## Changes

### Store#append
- Change INSERT to `ON CONFLICT (event_id) DO NOTHING`
- Use `RETURNING` to detect skipped rows (0 tuples = duplicate)
- `filter_map` over results, return only actually-inserted SequencedEvents

## Tests
- Appending same event twice returns empty array on second call
- DB contains exactly 1 row
- Mixed batch: some new, some duplicate -- only new ones returned
- Idempotent append does not trigger ConditionNotMet

## Done When
- Duplicate event_ids silently skipped
- Return value accurately reflects what was inserted
- `bundle exec rake` green
