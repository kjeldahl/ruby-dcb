# Step 4: Store#read

## Goal
Implement reading events from the store, filtered by a Query, returned as a streaming Enumerator.

## Files to Create
- `lib/dcb_event_store/store.rb`
  - `DcbEventStore::Store.new(conn)` -- takes a `PG::Connection`
  - `Store#read(query)` -- returns an `Enumerator` of `SequencedEvent`

## Behavior
- Translates Query into SQL WHERE clause:
  - Each QueryItem becomes: `(type = ANY($n) AND tags @> $m::text[])`
  - If QueryItem has empty event_types, omit the type clause
  - If QueryItem has empty tags, omit the tags clause
  - Multiple QueryItems are OR'd together
  - `Query.all` (match_all?) -> no WHERE clause
- Results ordered by `sequence_position ASC`
- Returns `Enumerator` that fetches rows in batches of 1000 using PostgreSQL cursors or LIMIT/OFFSET
- Each row mapped to `SequencedEvent` with proper type coercion (sequence_position to Integer, data from JSON string to Hash, tags from PG array to Ruby array, created_at to Time)

## Done When
- `store.read(Query.all)` on empty store returns empty enumerator
- After manually inserting events via SQL, `store.read(query)` correctly filters by:
  - Event type only
  - Tags only
  - Event type + tags combined
  - OR across multiple QueryItems
- Returned SequencedEvents have correct types for all fields
- Enumerator is lazy (doesn't load all rows at once) -- verified by reading first N from a large set
