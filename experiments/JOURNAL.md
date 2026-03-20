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

## Summary

| Experiment | Sequential p50 | Concurrent p50 | Concurrent ops/sec | Verdict |
|-----------|---------------|---------------|-------------------|---------|
| Baseline | 0.65ms | 93.28ms | 58 | — |
| EXISTS vs COUNT | 0.64ms | 79.47ms | 59 | No change |
| **Per-tag locks** | 0.66ms | **36.14ms** | 52 | **Best p50** |
| CTE (single stmt) | 0.68ms | 69.44ms | 62 | Marginal |
| Skip-lock | 0.63ms | 43.10ms | 56 | Bad tail latency |

## Conclusions

1. **Sequential bottleneck is DecisionModel.build (30ms)**, not the append
   path (0.65ms). Optimizing the read/fold path would have the biggest
   single-writer impact.

2. **Concurrent bottleneck is the global advisory lock.** Per-tag locks
   (Exp 2) are the most promising approach — 2.6x better p50 latency. But
   they shift contention to PG I/O, so throughput doesn't fully scale.

3. **Condition check is already fast** (0.4ms). EXISTS vs COUNT and CTE
   approaches don't help because the GIN index already makes this cheap.

4. **Read is already outside the lock.** No improvement possible here.

5. **Skip-lock polling is counterproductive.** PG's built-in lock queue
   is fairer than application-level retry.

## Recommended next steps

- **For single-writer latency:** Optimize DecisionModel.build — consider
  COUNT-based projections (SQL aggregation instead of Ruby fold), or
  caching/materialized views for hot projections.

- **For concurrent throughput:** Adopt per-tag locks. Consider combining
  with CTE to minimize time under lock. May need PG connection pooling
  to handle the increased concurrent connection load.
