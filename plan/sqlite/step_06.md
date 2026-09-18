# Step 6: Subscribe via base loop + polling

## Changes
- `SqlStore#subscribe(query, after: nil, &)`:
```ruby
catch_up = after ? read_from(query, after: after) : read(query)
last_pos = instrument_subscribe(catch_up, query, :catch_up, &) || after
listen
loop do
  wait_for_append
  events = read_from(query, after: last_pos || 0)
  last_pos = instrument_subscribe(events, query, :live, &) || last_pos
end
ensure
  unlisten
```
- `PostgresStore`: `listen` = `LISTEN events_appended`, `wait_for_append` =
  `@conn.wait_for_notify`, `unlisten` = `UNLISTEN` (rescue). Behavior unchanged.
- `SqliteStore`: `wait_for_append`: `sleep @poll_interval` until `PRAGMA data_version`
  differs from last seen. Note: `data_version` only changes on *other* connections'
  commits -> subscriber must use its own `SQLite3::Database`. Document. Same-connection
  appends: also fall through after `@poll_interval` regardless (cheap read, keeps
  single-connection usage working).
- `test/sqlite/test_subscribe.rb`: port `test/integration/test_subscribe.rb` (subscriber
  thread opens 2nd `SQLite3::Database` on same file). Lag assertions ms-precision safe.

## Done when
- PG subscribe tests unchanged & green. SQLite subscribe tests green, `subscribe.dcb`
  instrumentation events observed with both modes.
