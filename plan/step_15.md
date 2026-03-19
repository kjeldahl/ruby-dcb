# Step 15: read_from (Catch-Up Reads)

## Goal
Add `Store#read_from(query, after:)` to read events matching a query starting after a given sequence position. Building block for catch-up subscriptions.

## Changes

### Store
- New method `read_from(query, after:)` -- same as `read` but appends `sequence_position > $N` to WHERE clause
- Reuse `build_read_sql` with `after:` keyword argument
- Returns Enumerator, same batching as `read`

## Tests
- `read_from` with `after: 0` returns all events
- `read_from` with `after: N` skips first N events
- Filters by query AND position
- Empty result when `after` is past last event

## Done When
- `Store#read_from` works for all query types (match_all, filtered)
- `bundle exec rake` green
