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

Measured when every append took one global advisory lock
(`pg_advisory_xact_lock(0)`), so these numbers are a fully serialized
baseline. Appends have locked per tag since; the lock set as shipped today is
measured in "Per-tag locks on the tags written" below.

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
- **Advisory lock is the throughput ceiling** — single-writer serialization at the time of this table; per-tag locks since (see below)
- **Near-zero data loss** — 98.9-100% success rate under sustained concurrent load

## A note on the PostgreSQL read numbers above

The PostgreSQL tables above were measured right after the `COPY` seed, before
any vacuum. A bulk load leaves the GIN index with a large *pending list*
(`fastupdate`), and every `tags @>` lookup scans it until a vacuum merges it
into the index: the same 5-event student read costs 4.2 ms before and 0.4 ms
after `VACUUM` (or `gin_clean_pending_list`) at 100k events. Autovacuum does
that within minutes on a real deployment, so the seeder now runs
`VACUUM ANALYZE` (`examples/performance.rb`), and PostgreSQL tag reads measured
from here on are roughly 10x cheaper than the "Single student" and
"Student+course intersection" rows above suggest. The snapshot investigation in
`SNAPSHOTS.md` was measured with the vacuumed seed.

## PostgreSQL vs SQLite (same machine)

Hardware and versions for this section only: x86_64 Linux container, 4 cores,
15 GB RAM, Ruby 3.3.6, PostgreSQL 16.13 (local socket), SQLite 3.53.2 (`sqlite3`
gem 2.9.6, WAL, `synchronous=NORMAL`, database file on the container's disk).
**Not the Apple Silicon machine the tables above were measured on** — compare the
two backends with each other here, not with the numbers further up.

Both runs are `bundle exec ruby examples/performance.rb 20000 100` with
`DCB_BACKEND` switched: 100 courses, 20,000 students, 5 subscriptions each,
100,100 seeded events, 1,500 capacity/course, ~1,000 subscriptions on the
course the "popular course" cases hit.

### Seeding

| | PostgreSQL | SQLite |
|---|-----------|--------|
| 100k events | 1.0s (COPY) | 2.7s (prepared INSERTs, 5k/transaction) |
| storage incl. indexes | 36 MB (`events` + 5 indexes) | 36 MB (`events` + `event_tags`, 204k rows) |

### Reads (p50, 50 iterations)

| Query | PostgreSQL | SQLite | Notes |
|-------|-----------|--------|-------|
| Single course (~1,000 events) | 22.1ms | 23.5ms | dominated by row decoding, not lookup |
| Single student (5 events) | 4.1ms | 0.18ms | SQLite is in-process: no round trip |
| Student+course intersection (0-1 events) | 6.3ms | 0.24ms | same |

### Reads, DecisionModel and append (p50, 50 iterations)

| Scenario | PostgreSQL | SQLite |
|----------|-----------|--------|
| DecisionModel.build, popular course | 75.6ms | 42.6ms |
| DecisionModel.build, random course | 68.7ms | 43.0ms |
| append + condition (new student) | 69.1ms | 48.1ms |
| condition check only (no write) | 66.4ms | 44.2ms |

Each decision model is five projections over one read, so the per-statement
round trip is paid once per projection — which is exactly where the in-process
backend wins. The remaining cost on both is folding the ~1,000 subscription
events of the popular course.

### Concurrency

| | PostgreSQL | SQLite |
|---|-----------|--------|
| 10 threads x 5 ops | 21 ops/sec, 47/50 | 19 ops/sec, 46/50 |
| 10 procs x 5 ops | 34 ops/sec, 49/50 | 66 ops/sec, 46/50 |
| 10 procs x 20 ops | 54 ops/sec, 187/200 | 51 ops/sec, 191/200 |
| 10 procs x 50 ops | 90 ops/sec, 459/500 | 70 ops/sec, 479/500 |
| 10 procs x 100 ops | 87 ops/sec, 933/1000 | 72 ops/sec, 936/1000 |

Throughput lands in the same range, for different reasons: PostgreSQL serializes
appends on per-tag advisory locks, SQLite on the database's single write lock
(`BEGIN IMMEDIATE`, with the GVL-releasing busy handler doing the waiting). The
missing operations in both columns are the workload's own constraint failures
(course full), not lost writes.

### Takeaway

SQLite is the faster backend for a single process at this scale — no round trip
per statement, and `event_tags` matches GIN's selectivity. PostgreSQL's
advantages appear where SQLite structurally cannot follow: appends that must
proceed in parallel across disjoint tags, a database shared by many hosts, and
`LISTEN/NOTIFY` subscriptions that wake without polling.

## Per-tag locks on the tags written (#42)

Before #42 a PostgreSQL append locked only the tags its *condition* named, and
an unconditional append one global key, so a writer on `course:c1` never waited
for a condition on `course:c1`. Now every append takes the global key shared
plus one exclusive key per tag its events carry or its condition names (a
condition naming no tag takes the global key exclusive). In this workload each
`StudentSubscribedToCourse` append therefore holds three keys instead of two:
the student tag its event carries joins the course tag its condition already
locked.

Same benchmark as the section above, `bundle exec ruby examples/performance.rb
20000 100`, on an x86_64 Linux container with 4 cores and 15 GB RAM, Ruby 3.3.6,
PostgreSQL 16.15 (local socket), SQLite 3.53.2 (`sqlite3` gem 2.9.6). A faster
host than the one the section above was measured on (the same decision model
builds in a third of the time), so compare within this section only. Two runs
per PostgreSQL column, one for SQLite, whose lock hook is a no-op and did not
change.

### Reads, DecisionModel and append (p50, 50 iterations)

| Scenario | PG before #42 | PG after #42 | SQLite |
|----------|--------------|-------------|--------|
| read single course (~1,000 events) | 11.2 / 11.4 ms | 11.9 / 11.6 ms | 11.4 ms |
| DecisionModel.build, popular course | 22.3 / 19.6 ms | 23.1 / 22.4 ms | 24.6 ms |
| DecisionModel.build, random course | 21.8 / 22.7 ms | 21.7 / 20.7 ms | 26.2 ms |
| append + condition (new student) | 23.9 / 23.8 ms | 24.0 / 22.1 ms | 26.8 ms |
| condition check only (no write) | 22.8 / 18.9 ms | 23.1 / 21.5 ms | 23.9 ms |

### Concurrency (ops/sec, succeeded/total)

| | PG before #42 | PG after #42 | SQLite |
|---|--------------|-------------|--------|
| 10 threads x 5 ops | 32, 47/50 / 41, 50/50 | 38, 46/50 / 38, 48/50 | 32, 49/50 |
| 10 procs x 5 ops | 58, 49/50 / 94, 46/50 | 114, 47/50 / 113, 49/50 | 82, 49/50 |
| 10 procs x 20 ops | 129, 188/200 / 135, 188/200 | 132, 187/200 / 138, 189/200 | 104, 184/200 |
| 10 procs x 50 ops | 152, 478/500 / 142, 469/500 | 135, 460/500 / 143, 469/500 | 110, 469/500 |
| 10 procs x 100 ops | 142, 931/1000 / 141, 937/1000 | 138, 932/1000 / 138, 951/1000 | 116, 959/1000 |

### Takeaway

The extra lock per event tag is not measurable: every before/after pair sits
inside the run-to-run spread of the same code. The workload's contention is
the course tag both versions already locked (ten workers over 100 courses), and
the added student key is uncontended (one student per operation), so the only
new cost is one more `pg_advisory_xact_lock` call inside a transaction that
already spends ~20 ms folding the popular course. The shared global key costs
the same: shared locks never wait for each other, and nothing in this workload
takes it exclusive. The missing operations remain the workload's own constraint
failures (course full), as before.

## SQLite tag lookup: `event_tags` table vs `json_each` scan

Microbenchmark of the **count query alone** — the statement the append
condition runs inside the write transaction — not a full append. SQLite 3.53,
WAL, 20 event types, 2 tags per event. Column A is tag containment evaluated as
`json_each` over the `events.tags` JSON column; column B is the shipped design,
a `event_tags(tag, sequence_position)` index table.

| events | query | A `json_each` scan | B `event_tags` |
|--------|-------|-----------------|--------------|
| 200k | tags only | 77 ms | 0.05 ms |
| 200k | type + tags | 9.6 ms | 0.06 ms |
| 1M | tags only | 400 ms | 0.2-0.8 ms |
| 1M | type + tags | 52 ms | 0.2-0.8 ms |
| 1M | insert cost | 30 s | 46 s (+55%, 2 extra rows/event) |
| 1M | db size | ~165 MB | ~210 MB (+45 MB) |

A is O(rows of the matching type) per condition check, inside the serialized
write transaction — a throughput ceiling of roughly 20 appends/sec at 1M events
of one type. B is O(matches), at the price of one index row per tag per event;
PostgreSQL pays the same cost in GIN maintenance. Hence the second table in the
SQLite schema.

## Row decode: what a replay actually spends

`examples/decode_performance.rb`, 50k events, best of 5. Replay here is a full
`store.read` over the stream — query, driver, and turning every row back into a
`SequencedEvent`. Once the query is indexed, decoding is what is left.

`created_at` is the only timestamp the gem parses (payload timestamps sit inside
the JSON `data` column and are never touched), once per row. It used to go
through `Time.parse`, which cost more than all the other columns put together.

| replay | before | with `SqlStore::Timestamp` | + driver-native `created_at` |
|--------|--------|------------------------|--------------------------|
| PostgreSQL | 17.98 us/event | 9.57 | **6.41** |
| SQLite | 17.57 us/event | 8.69 | **5.95** |

Where the remaining microseconds go, per row:

| step | PostgreSQL | SQLite |
|------|-----------|--------|
| whole row -> `SequencedEvent` | 2.75 us | 2.72 us |
| JSON payload | 0.93 us | 0.76 us |
| tags | 0.38 us | 0.40 us |
| `Integer()` casts | 0.19 us | 0.11 us |
| **timestamp** | **0.09 us** | **0.29 us** |

The timestamp column, by the route it takes:

| route | PostgreSQL | SQLite |
|-------|-----------|--------|
| driver hands back a decoded value | 0.08 us | 0.27 us |
| `SqlStore::Timestamp` reads the text | 2.60 us | 1.75 us |
| `Time.parse` reads the text | 10.52 us | 10.30 us |

Three ways to read one column, two orders of magnitude apart:

- **Driver-native.** PostgreSQL decodes `TIMESTAMPTZ` in C, through the type map
  `PostgresStore` installs on its connection. SQLite has no date type, so
  `created_at` is `INTEGER` epoch microseconds, which comes back as an Integer
  needing no parsing. Resolution is unchanged — SQLite's clock is
  millisecond-grained either way.
- **`SqlStore::Timestamp`.** Both backends emit one fixed shape, so it validates
  with a single anchored match and then reads digits out of known byte offsets.
  This is the fallback for text: a database written before `created_at` became
  `INTEGER`, a column typed `TIMESTAMP` rather than `TIMESTAMPTZ`, a replaced
  type map.
- **`Time.parse`.** Correct for anything, and the cost of that generality is
  trying dozens of formats before recognising either of ours. Still the fallback
  for a timestamp outside the recognised shape, so nothing stops being readable.
