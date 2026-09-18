# Step 5: SqliteStore read + append

## Changes
- `sqlite_store/dialect.rb`: `SqliteStore::Dialect`
  - `placeholder` -> `"?"`; `encode_list` -> `JSON.generate`; `decode_list` -> `JSON.parse`
  - `type_in` -> `type IN (SELECT value FROM json_each(?))`
  - `tags_contain` -> `NOT EXISTS (SELECT 1 FROM json_each(?) r WHERE NOT EXISTS
    (SELECT 1 FROM json_each(events.tags) t WHERE t.value = r.value))`
  - no casts.
- `sqlite_store.rb`: `SqliteStore.new(db, upcaster:, subscribe_instrumentation:,
  poll_interval: 0.1)` (`db` = `SQLite3::Database`).
  - `with_write_transaction`: `BEGIN IMMEDIATE` / `COMMIT` / `ROLLBACK` on error.
  - `acquire_locks!`: no-op. `count_matching`: `condition_sql` -> `get_first_value`.
  - `insert_event`: per-row `INSERT ... ON CONFLICT(event_id) DO NOTHING RETURNING
    sequence_position, created_at`; empty result -> nil.
  - `fetch_batch`: `read_sql` + `LIMIT ?`, `db.execute` with `results_as_hash`.
  - `notify_appended`: no-op.
- `ConditionNotMet` message identical to PG.
- `test/sqlite/test_sqlite_store.rb`: `include StoreContract`, `build_store` -> fresh
  tempfile DB. Plus `test_same_operations_produce_equivalent_results` vs InMemory
  (copy pattern from `test_store_equivalence.rb`).
- `test/unit/test_sqlite_dialect.rb`, `test_sql_builder.rb` gets SQLite variant asserting
  exact SQL strings.

## Done when
- StoreContract green on SQLite. Contract now runs on 3 backends.
