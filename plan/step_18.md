# Step 18: Multi-tag Advisory Locks

## Goal

Replace the global advisory lock with per-tag advisory locks. Validated
by experiments (see `experiments/JOURNAL.md`): 4.7-14.4x concurrent
latency improvement, up to 3.1x throughput gain, no regressions.

## Changes

### 1. Schema: add `acquire_sorted_advisory_locks` function

Add to `Schema::CREATE_SQL`:

```sql
CREATE OR REPLACE FUNCTION acquire_sorted_advisory_locks(lock_keys bigint[])
RETURNS void AS $$
DECLARE k bigint;
BEGIN
  FOREACH k IN ARRAY (SELECT array_agg(x ORDER BY x) FROM unnest(lock_keys) x)
  LOOP
    PERFORM pg_advisory_xact_lock(k);
  END LOOP;
END;
$$ LANGUAGE plpgsql;
```

Acquires multiple advisory locks in sorted order (one round-trip,
deadlock-free). Falls back to global lock(0) when no tags present.

### 2. Store#append: compute lock keys from condition tags

Replace:
```ruby
@conn.exec("SELECT pg_advisory_xact_lock($1)", [APPEND_LOCK_KEY])
```

With:
```ruby
lock_keys = condition_lock_keys(condition)
pg_arr = "{#{lock_keys.join(",")}}"
@conn.exec_params("SELECT acquire_sorted_advisory_locks($1::bigint[])", [pg_arr])
```

New private method `condition_lock_keys(condition)`:
- Extract all unique tags from `condition.fail_if_events_match.items`
- Hash each tag to a bigint: `Zlib.crc32(tag)` (deterministic across processes)
- Sort, return array
- If no tags (type-only query) or no condition: return `[0]` (global lock)

### 3. Store#append: check condition once, then insert

The condition check runs once before inserting all events. This preserves
correct multi-event batch semantics (all-or-nothing per the DCB spec).

**CTE alternative (not implemented):** A single-statement CTE could
merge the condition check and multi-row INSERT into one round-trip:

```sql
WITH cond AS (SELECT COUNT(*) FROM events WHERE ...)
INSERT INTO events (event_id, type, data, tags, ...)
SELECT * FROM (VALUES ($1,$2,...), ($8,$9,...)) AS v(...)
WHERE NOT EXISTS (SELECT 1 FROM cond WHERE count > 0)
ON CONFLICT (event_id) DO NOTHING
RETURNING sequence_position, created_at
```

This saves one round-trip (~0.4ms) but adds complexity: parameter
numbering scales with event count, and disambiguating partial RETURNING
results (condition failure vs idempotent skip when fewer rows return
than events passed) requires a fallback COUNT query. A per-event CTE
loop is **incorrect** — it re-checks the condition after each insert,
causing false `ConditionNotMet` on the second event in a batch.

## Tests

All existing tests must pass unchanged — the behavior is identical,
only the locking granularity and SQL round-trips change.

### New test: cross-tag concurrent correctness

Add to `test/concurrency/test_concurrent_append.rb`:

**test_cross_boundary_concurrent_safety**
- 10 threads, each subscribing the SAME student to a different course
- Student limit = 5 courses (from the course subscription model)
- Assert: exactly 5 succeed, 5 raise ConditionNotMet
- Proves multi-tag locks correctly serialize across overlapping boundaries

**test_independent_tags_run_concurrently**
- 10 threads, each appending events with non-overlapping tags
- Measure wall-clock time
- Assert: total time < N * single-append-time (parallelism observed)
- Proves per-tag locks enable true concurrency

## Files Changed

- `lib/dcb_event_store/schema.rb` — add stored procedure to CREATE_SQL
- `lib/dcb_event_store/store.rb` — per-tag locking, refactored append
- `test/concurrency/test_concurrent_append.rb` — add 2 new tests

## Done When

- All 77 existing tests pass (no behavior change)
- 2 new concurrency tests pass
- `bundle exec rubocop lib/ test/` clean
- CI green on Ruby 3.3, 3.4, 4.0
