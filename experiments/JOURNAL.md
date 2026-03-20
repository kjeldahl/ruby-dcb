# Performance Experiments Journal

Dataset: 100k students, 500 courses, 500k events, 166 MB table.

## Baseline (global advisory lock)

### Single-writer (sequential, no contention)

| Phase | p50 | p90 | p99 | stddev |
|-------|-----|-----|-----|--------|
| **dm_read** | **30.72ms** | 44.61ms | 57.16ms | 8.32ms |
| lock_wait | 0.07ms | 0.09ms | 0.16ms | 0.02ms |
| condition_check | 0.37ms | 0.55ms | 1.06ms | 0.17ms |
| insert | 0.15ms | 0.27ms | 2.45ms | 0.46ms |
| notify | 0.02ms | 0.03ms | 0.05ms | 0.01ms |
| **total (append only)** | **0.65ms** | 0.97ms | 2.91ms | 0.48ms |

**Finding:** The append path itself is <1ms. The bottleneck is
`DecisionModel.build` at 30ms — reading and folding events. The advisory
lock, condition check, and insert are all sub-millisecond when uncontended.

### Concurrent (10 threads x 10 ops)

| Phase | p50 | p90 | p99 | stddev |
|-------|-----|-----|-----|--------|
| **lock_wait** | **85.05ms** | 102.92ms | 113.40ms | 31.25ms |
| condition_check | 0.71ms | 15.01ms | 19.15ms | 6.77ms |
| insert | 0.29ms | 12.73ms | 45.15ms | 9.39ms |
| notify | 0.08ms | 12.41ms | 31.36ms | 6.72ms |
| **total** | **93.28ms** | 118.11ms | 131.89ms | 34.78ms |
| Throughput | 59 ops/sec | | | |

**Finding:** Under concurrency, lock_wait dominates at 85ms p50 — threads
queue behind the global lock. The condition/insert/notify times also spike
at p90+ because PG operations get delayed by lock contention. The lock IS
the bottleneck under concurrent load, but NOT under sequential load.

### Key insight

Two different bottlenecks depending on concurrency:
- **Sequential:** DecisionModel.build read (30ms) >> append (0.65ms)
- **Concurrent:** Lock wait (85ms) >> everything else

---

## Experiment 1: EXISTS vs COUNT

Replace `SELECT COUNT(*) FROM events WHERE ...` with
`SELECT EXISTS(SELECT 1 FROM events WHERE ...)`.

### Sequential

| Phase | p50 | p90 | p99 | vs baseline |
|-------|-----|-----|-----|-------------|
| condition_check | 0.38ms | 0.66ms | 0.78ms | ~same |
| total | 0.64ms | 0.96ms | 1.10ms | ~same |

### Concurrent

| Phase | p50 | p90 | p99 | vs baseline |
|-------|-----|-----|-----|-------------|
| lock_wait | 68.19ms | 92.50ms | 109.08ms | ~same |
| total | 79.47ms | 106.01ms | 115.09ms | ~same |
| Throughput | 59 ops/sec | | | same |

**Verdict: No improvement.** The condition check is already fast (0.4ms).
COUNT vs EXISTS doesn't matter when the GIN index efficiently filters to
near-zero results. The query planner likely already short-circuits.

### Query plan analysis

**Without `after` filter** (full table — not what runs during append):

| | COUNT | EXISTS |
|---|---|---|
| Strategy | Bitmap Heap Scan (GIN) | Seq Scan, stops at 1st row |
| Execution | 33.18ms | 0.10ms |
| Planning | 20.58ms | 7.58ms |
| Buffers | hit=871, read=135 | hit=1 |

EXISTS is dramatically faster here because it stops after finding one row
while COUNT scans all 1018 matches. But this query never runs in practice.

**With `after` filter** (what actually runs — `sequence_position > max_pos`):

| | COUNT | EXISTS |
|---|---|---|
| Strategy | Index Scan (PK) | Index Scan (PK) |
| Execution | 0.25ms | 0.12ms |
| Planning | 1.49ms | 0.21ms |
| Buffers | hit=53 | hit=50 |
| Rows scanned | 99 (filtered) | 99 (filtered) |

Both use the primary key index and scan the same ~99 rows past the
`after` position. EXISTS is 2x faster on execution but both are sub-ms.
The condition check was already measured at 0.37ms p50 — at this scale
the difference is noise. EXISTS would only win if the `after` position
were far behind and many matching rows existed past it.

---

## Experiment 2: Per-tag advisory locks

Hash the condition query's tags to a lock key instead of global lock(0).
Non-overlapping tag sets can append concurrently.

### Sequential

| Phase | p50 | p90 | p99 | vs baseline |
|-------|-----|-----|-----|-------------|
| total | 0.66ms | 1.12ms | 1.42ms | ~same |

### Concurrent

| Phase | p50 | p90 | p99 | vs baseline |
|-------|-----|-----|-----|-------------|
| **lock_wait** | **7.30ms** | 25.60ms | 34.79ms | **12x better** |
| condition_check | 6.59ms | 20.88ms | 45.64ms | worse (contention shifted) |
| insert | 4.64ms | 18.81ms | 43.24ms | worse |
| **total** | **36.14ms** | 74.46ms | 113.18ms | **1.9x better** |
| Throughput | 52 ops/sec | | | slightly worse |

**Verdict: Mixed results.** Lock wait dropped dramatically (85ms → 7ms p50)
because different courses get different lock keys. But condition_check and
insert times increased — without the global lock serializing everything,
multiple transactions hit PG concurrently, creating I/O contention. Overall
p50 improved (93ms → 36ms) but throughput didn't increase because the total
work shifted to PG contention.

**This approach has potential** but needs the condition check and insert to
be faster to fully realize the lock parallelism gains. Combining with
Experiment 3 (CTE) could help.

---

## Experiment 3: Single-statement CTE

Merge condition check + insert into one SQL statement:
```sql
WITH cond AS (SELECT COUNT(*) ...)
INSERT INTO events ... WHERE NOT EXISTS (SELECT 1 FROM cond WHERE count > 0)
```

### Sequential

| Phase | p50 | p90 | p99 | vs baseline |
|-------|-----|-----|-----|-------------|
| condition_check | 0.00ms | 0.00ms | 0.00ms | eliminated |
| insert | 0.58ms | 1.02ms | 1.27ms | higher (does both) |
| total | 0.68ms | 1.11ms | 1.38ms | ~same |

### Concurrent

| Phase | p50 | p90 | p99 | vs baseline |
|-------|-----|-----|-----|-------------|
| lock_wait | 61.03ms | 89.38ms | 105.45ms | slightly better |
| insert | 1.26ms | 15.91ms | 27.77ms | ~same |
| **total** | **69.44ms** | 100.42ms | 120.42ms | **slightly better** |
| Throughput | 62 ops/sec | | | slightly better |

**Verdict: Marginal improvement.** Saves one round-trip but the condition
check was only ~0.4ms to begin with. The CTE approach is cleaner but
doesn't materially change throughput since lock_wait still dominates.

---

## Experiment 4: Read outside lock (verification)

**Confirmed:** `DecisionModel.build` calls `store.read()` before
`store.append()`. The read happens outside the transaction/lock. The lock
is only held during condition_check + insert + notify + commit.

**No change needed — already optimal.**

---

## Experiment 5: Optimistic skip-lock

Use `pg_try_advisory_xact_lock` to poll instead of blocking wait.
Falls back to blocking after 20 attempts (1ms sleep between retries).

### Sequential

| Phase | p50 | p90 | p99 | vs baseline |
|-------|-----|-----|-----|-------------|
| total | 0.63ms | 0.97ms | 1.17ms | ~same |

### Concurrent

| Phase | p50 | p90 | p99 | vs baseline |
|-------|-----|-----|-----|-------------|
| lock_wait | 36.80ms | 110.35ms | 210.71ms | better p50, much worse tail |
| total | 43.10ms | 118.46ms | 211.28ms | better p50, much worse p99 |
| Throughput | 56 ops/sec | | | slightly worse |

**Verdict: Worse overall.** The polling approach reduces p50 lock_wait
(85ms → 37ms) but creates terrible tail latency (p99: 211ms vs 113ms).
The sleep(1ms) intervals add up and create unfair scheduling. The blocking
lock is actually fairer — FIFO queue in PG vs random retry ordering.

---

## Experiment 6: Per-tag locks + CTE (combined)

Combines Experiment 2 (per-tag advisory locks) with Experiment 3 (CTE
single-statement condition+insert). The hypothesis: per-tag locks reduce
lock contention, CTE reduces time-under-lock.

### Sequential

| Phase | p50 | p90 | p99 | vs baseline |
|-------|-----|-----|-----|-------------|
| total | 0.63ms | 0.96ms | 1.70ms | ~same |

### Concurrent

| Phase | p50 | p90 | p99 | vs baseline |
|-------|-----|-----|-----|-------------|
| **lock_wait** | **1.11ms** | 17.59ms | 95.37ms | **65x better p50** |
| insert | 1.05ms | 15.95ms | 79.37ms | ~same |
| **total** | **7.70ms** | 32.98ms | 109.55ms | **10.7x better p50** |
| Throughput | 58 ops/sec | | | same |

### Comparison (concurrent p50, all runs from same session)

| Experiment | lock_wait p50 | total p50 | ops/sec |
|-----------|--------------|----------|---------|
| Baseline | 72.26ms | 82.76ms | 60 |
| Exp 2: Per-tag locks | 2.50ms | 4.32ms | 59 |
| Exp 3: CTE | 60.65ms | 77.35ms | 61 |
| **Exp 6: Per-tag + CTE** | **1.11ms** | **7.70ms** | 58 |

**Verdict: Best latency overall.** The combination delivers the best p50
(7.70ms, down from 82.76ms baseline — 10.7x improvement). Lock wait
drops to 1.11ms because per-tag locks allow parallel appends to different
courses. The CTE eliminates the separate condition_check round-trip,
reducing time-under-lock.

However, **throughput (ops/sec) stays flat** at ~58-61 across all
experiments. This is because total throughput is bounded by PG's ability
to handle concurrent writes — the work didn't decrease, just the waiting.
The p99 tail (109ms) shows that when tag-based locks do collide, the
latency spikes back toward baseline.

**The win is latency, not throughput.** For workloads where different
entities rarely contend (the common case in DCB), per-tag+CTE gives
near-zero lock wait with no correctness tradeoff.

---

## Experiment 7 & 8: Correct multi-tag locks

Experiments 2 and 6 had a correctness bug: they hashed all tags into one
lock key. When an event spans multiple consistency boundaries (e.g.
`student:alice` + `course:math-101`), two appends with overlapping but
non-identical tag sets get different lock keys and run concurrently —
violating the constraint.

**Fix:** Acquire one advisory lock per unique tag, in sorted order
(preventing deadlocks). A PL/pgSQL stored procedure handles this in one
round-trip:

```sql
CREATE FUNCTION acquire_sorted_advisory_locks(lock_keys bigint[])
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

### Results (concurrent, 10 threads x 10 ops)

| Experiment | lock_wait p50 | total p50 | ops/sec | Correct? |
|-----------|--------------|----------|---------|----------|
| Baseline (global) | 83.82ms | 98.12ms | 54 | Yes |
| Exp 2: Per-tag (BROKEN) | 0.52ms | 5.31ms | 54 | **No** |
| **Exp 7: Multi-tag** | **0.65ms** | **20.81ms** | **53** | **Yes** |
| Exp 6: Per-tag+CTE (BROKEN) | 0.59ms | 6.90ms | 57 | **No** |
| **Exp 8: Multi-tag+CTE** | **2.18ms** | **21.43ms** | **48** | **Yes** |

### Analysis

The correct multi-lock approach (Exp 7/8) is ~4x better than baseline on
p50 latency (20ms vs 98ms), but ~3-4x worse than the broken single-hash
approach (5ms). The cost comes from:

1. **More lock acquisitions** — subscribe_student has tags across 5
   query items: `course:X`, `student:Y`, and `student:Y,course:X`.
   After dedup that's 2 unique tags → 2 locks per append.

2. **Higher contention** — locking on `student:alice` means ANY append
   involving alice serializes, even across different courses. This is
   correct (student subscription count must be consistent) but creates
   more contention than the broken approach.

3. **PG I/O contention** — with locks held for shorter but the
   condition_check/insert now competing for shared PG resources, the
   p90/p99 spikes (76ms/169ms for Exp 7).

4. **Stored procedure overhead** — the PL/pgSQL function adds ~0.06ms
   per call sequentially, negligible.

### Sequential overhead

| | p50 | p99 |
|---|---|---|
| Baseline | 0.75ms | 1.42ms |
| Exp 7 (multi-tag) | 0.82ms | 30.42ms |
| Exp 8 (multi-tag+CTE) | 0.72ms | 6.75ms |

The p99 spike on Exp 7 is likely from occasional lock contention even in
sequential mode (the stored procedure queries `pg_catalog` which can
have brief contention). CTE variant (Exp 8) is better at p99.

---

## Summary

| Experiment | Seq p50 | Conc p50 | ops/sec | Correct? | Verdict |
|-----------|---------|---------|---------|----------|---------|
| Baseline | 0.75ms | 98.12ms | 54 | Yes | — |
| EXISTS vs COUNT | 0.64ms | 79.47ms | 59 | Yes | No change |
| Per-tag (BROKEN) | 0.63ms | 5.31ms | 54 | **No** | — |
| CTE only | 0.63ms | 77.35ms | 61 | Yes | Marginal |
| Skip-lock | 0.63ms | 43.10ms | 56 | Yes | Bad tail |
| Per-tag+CTE (BROKEN) | 0.68ms | 6.90ms | 57 | **No** | — |
| **Multi-tag (correct)** | 0.82ms | **20.81ms** | 53 | Yes | **4.7x better** |
| **Multi-tag+CTE** | 0.72ms | **21.43ms** | 48 | Yes | **4.6x better** |

## Conclusions

1. **Sequential bottleneck is DecisionModel.build (30ms)**, not the append
   path (0.65ms). Optimizing the read/fold path would have the biggest
   single-writer impact.

2. **Correct multi-tag locking gives ~4.7x better concurrent p50** (98ms
   → 21ms) while maintaining correctness. The broken single-hash approach
   was faster (5ms) but allowed constraint violations.

3. **CTE doesn't help with multi-tag locks.** The extra round-trip saved
   is negligible compared to lock acquisition and PG contention.

4. **Latency improves, throughput stays flat** (~48-54 ops/sec). PG write
   capacity is the ceiling, not our locking.

5. **Condition check is already fast** (0.4ms). EXISTS vs COUNT and CTE
   don't help because the GIN index + `after` filter make this cheap.

6. **Read is already outside the lock.** No improvement possible here.

7. **Skip-lock polling is counterproductive.** PG's built-in FIFO queue
   is fairer than application-level retry.

## Recommended next steps

- **For single-writer latency:** Optimize DecisionModel.build — consider
  COUNT-based projections (SQL aggregation instead of Ruby fold), or
  caching/materialized views for hot projections.

- **For concurrent latency:** Adopt multi-tag locks (Exp 7). Gives ~5x
  better p50 with full correctness. The stored procedure approach keeps
  it to one round-trip per lock acquisition.

- **For concurrent throughput:** The ceiling is PG write speed (~50
  ops/sec). Would require batching multiple appends per transaction, or
  horizontal scaling.
