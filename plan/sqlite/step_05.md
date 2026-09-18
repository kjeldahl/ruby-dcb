# Step 5: SqliteStore read + append

## Changes
- `sqlite_store/dialect.rb`: `SqliteStore::Dialect`
  - `placeholder` -> `"?"`; `encode_list` -> `JSON.generate`; `decode_list` -> `JSON.parse`
  - `type_in` -> `type IN (SELECT value FROM json_each(?))`
  - `tags_contain` -> `sequence_position IN (SELECT sequence_position FROM event_tags WHERE
    tag IN (SELECT value FROM json_each(?)) GROUP BY sequence_position HAVING COUNT(*) = ?)`
    (2 params: JSON list, tag count)
  - no casts.
- `sqlite_store.rb`: `SqliteStore.new(db, upcaster:, subscribe_instrumentation:,
  poll_interval: 0.1)` (`db` = `SQLite3::Database`).
  - `with_write_transaction`: `BEGIN IMMEDIATE` / `COMMIT` / `ROLLBACK` on error.
  - `acquire_locks!`: no-op. `count_matching`: `condition_sql` -> `get_first_value`.
  - `insert_event`: per-row `INSERT ... ON CONFLICT(event_id) DO NOTHING RETURNING
    sequence_position, created_at`; empty result -> nil. Then one `INSERT INTO event_tags`
    per tag (same txn). Fully consume/reset RETURNING statements before COMMIT (sqlite3 gem
    raises BusyException otherwise) -> use `db.execute`/`get_first_row`, not long-lived
    prepared statements.
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
