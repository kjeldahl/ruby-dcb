# DCB Event Store — Benchmark Results

Hardware: Apple Silicon, PostgreSQL local, Ruby 4.0.

## Dataset

| Scale | Courses | Students | Subs/student | Total events | Table size |
|-------|---------|----------|-------------|-------------|------------|
| 100k  | 500     | 100,000  | 5           | 500,500     | 166 MB     |
| 1M    | 2,000   | 1,000,000| 5           | 5,002,000   | 1.6 GB     |

## Read Performance (GIN index)

Tag-filtered queries scale sub-linearly — 10x data ≠ 10x latency.

| Query | 100k (p50) | 1M (p50) | Notes |
|-------|-----------|----------|-------|
| Single course | 20ms | 50ms | ~1000 subs/course at 100k, ~2500 at 1M |
| Single student | 2ms | 3ms | Always 5 events regardless of scale |
| Student+course intersection | 3ms | 5ms | 0-1 events, near-constant |

## DecisionModel.build (5-projection subscribe check)

The full subscribe_student decision model queries across course existence,
capacity, course subscription count, student subscription count, and
duplicate check — 5 projections merged into one read.

| Scenario | 100k (p50) | 1M (p50) |
|----------|-----------|----------|
| Popular course | 27ms | — |
| Random course | 41ms | — |

Dominated by course subscription count fold (largest result set).

## Append with Condition Check

Single-writer append including decision model build + advisory lock + insert + condition check:

| | 100k (p50) | stddev |
|---|-----------|--------|
| append + condition | 41ms | 6.7ms |

## Concurrent Throughput

Global advisory lock (`pg_advisory_xact_lock(0)`) serializes all appends.
This is the intended design — correctness first, optimize later.

### Threads (10 threads, shared process)

| | ops/sec | success rate |
|---|--------|-------------|
| 10 threads x 5 ops | 54 | 100% |

### Processes (10 forked workers, true parallelism)

Throughput is constant regardless of ops/proc — fork overhead amortizes away.

| ops/proc | total ops | elapsed | ops/sec | success rate |
|----------|-----------|---------|---------|-------------|
| 5        | 50        | 3.5s    | 14      | 100%        |
| 20       | 200       | 14.0s   | 14      | 99.5%       |
| 50       | 500       | 35.1s   | 14      | 99.4%       |
| 100      | 1,000     | 69.8s   | 14      | 98.9%       |

### Threads vs Processes

Threads show ~4x higher ops/sec (54 vs 14) because PG connections share
the process and the GVL is released during I/O. Both are bottlenecked by
the single advisory lock. The ~14 ops/sec process ceiling reflects true
per-operation cost: decision model read + lock acquire + condition check +
insert + notify ≈ 70ms.

## Key Takeaways

- **GIN tags scale well** — sub-linear growth, student lookups stay <5ms at 5M events
- **Decision model cost ∝ largest projection result set** — course subs dominate
- **Advisory lock is the throughput ceiling** — by design, single-writer serialization
- **Near-zero data loss** — 98.9-100% success rate under sustained concurrent load
