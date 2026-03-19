# Step 16: Real-Time Subscriptions (LISTEN/NOTIFY)

## Goal
Add `Store#subscribe(query, after:, &block)` for real-time event streaming. Catches up from a position, then listens for new events via PostgreSQL NOTIFY.

## Changes

### Store#append
- After COMMIT, send `NOTIFY events_appended, '<last_position>'` with the last inserted sequence position

### Store#subscribe
- If `after:` given, catch up using `read_from`; otherwise `read` all
- Track `last_pos` from catch-up events
- `LISTEN events_appended`
- Loop: `wait_for_notify` -> `read_from(query, after: last_pos)` -> yield events
- `UNLISTEN` in ensure block

## Tests
- Subscribe receives events appended after subscription starts (threaded test)
- Catch-up: subscribe with `after: N` delivers old + new events
- Only matching events delivered (query filtering)

## Implementation Notes
- `subscribe` blocks the calling thread (designed for worker processes)
- Each subscriber needs its own PG connection
- NOTIFY payload is the last position (used to trigger catch-up, not to deliver events)

## Done When
- `Store#subscribe` delivers real-time events
- Catch-up + live seamlessly merges
- `bundle exec rake` green
