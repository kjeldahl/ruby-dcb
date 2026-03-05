# Step 5: Store#append

## Goal
Implement atomic event appending with optimistic concurrency via append conditions.

## Files to Create/Modify
- `lib/dcb_event_store/store.rb` -- add `Store#append(events, condition = nil)`
- `lib/dcb_event_store/condition_not_met.rb` -- `DcbEventStore::ConditionNotMet < StandardError`

## Behavior
1. Open a transaction (`BEGIN`)
2. Acquire global advisory lock: `SELECT pg_advisory_xact_lock(0)`
3. If condition is provided:
   - Build WHERE clause from `condition.fail_if_events_match` (same SQL logic as read)
   - If `condition.after` is not nil, add `AND sequence_position > $after`
   - If `condition.after` is nil, no position filter (checks ALL events)
   - Execute `SELECT COUNT(*) FROM events WHERE ...`
   - If count > 0, ROLLBACK and raise `DcbEventStore::ConditionNotMet`
4. INSERT each event: `INSERT INTO events (type, data, tags) VALUES ($1, $2::jsonb, $3::text[]) RETURNING sequence_position, created_at`
5. COMMIT
6. Return array of `SequencedEvent` (the inserted events with their assigned positions)

## Error Handling
- `ConditionNotMet` raised when conflicting events found
- Transaction always rolled back on any error
- Advisory lock auto-released on transaction end (commit or rollback)

## Done When
- `store.append([event])` with no condition inserts and returns SequencedEvent with assigned sequence_position
- `store.append([event], condition)` succeeds when no conflicting events exist
- `store.append([event], condition)` raises `ConditionNotMet` when conflicting events exist after the given position
- `store.append([event], condition_with_nil_after)` raises `ConditionNotMet` when ANY matching events exist
- Multiple events in one append get sequential positions
- Failed appends leave no partial data in the table
