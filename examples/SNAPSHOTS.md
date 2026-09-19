# Snapshots and materialized streams — investigation

Question: other event sourcing frameworks speed up reads with snapshots
(stored projection state) and materialized streams (pre-selected, pre-decoded
event streams). What would they look like on a DCB store, and what do they
buy? This document records the design, the measurements and the verdict. The
code is in the gem (`Snapshot`, `Snapshots::*SnapshotStore`,
`MaterializedStreams`, the `snapshots:` option of `DecisionModel.build`) and
the numbers come from `examples/snapshot_benchmark.rb`.

Hardware for every table below: x86_64 Linux container, 4 cores, Ruby 3.3.6,
PostgreSQL 16.13 over a local socket (`fsync=off`), SQLite 3.53.2 (WAL,
`synchronous=NORMAL`). Compare rows with each other, not with other machines.

## 1. Where the time goes without snapshots

`DecisionModel.build` reads every event matching the projections' queries and
folds them. Profiled component by component for a single-projection build over
a course with N subscriptions, in a table of ~100k events (median of 20):

### PostgreSQL

| N | SQL fetch | row mapping | fold | full build | empty catch-up read | COUNT(*) |
|---:|---:|---:|---:|---:|---:|---:|
| 10 | 4.5 ms | 0.1 ms | 0.003 ms | 5.3 ms | 0.18 ms | 4.7 ms |
| 100 | 4.8 ms | 2.0 ms | 0.02 ms | 7.1 ms | 0.17 ms | 4.5 ms |
| 1,000 | 8.1 ms | 17.4 ms | 0.19 ms | 32.2 ms | 0.17 ms | 4.6 ms |
| 10,000 | 66.3 ms | 235.4 ms | 2.0 ms | 412.0 ms | 0.17 ms | 22.5 ms |

### SQLite

| N | SQL fetch | row mapping | fold | full build | empty catch-up read | COUNT(*) |
|---:|---:|---:|---:|---:|---:|---:|
| 10 | 0.12 ms | 0.14 ms | 0.003 ms | 0.38 ms | 0.08 ms | 0.05 ms |
| 100 | 0.44 ms | 1.5 ms | 0.02 ms | 2.6 ms | 0.11 ms | 0.07 ms |
| 1,000 | 4.6 ms | 18.4 ms | 0.18 ms | 27.0 ms | 0.45 ms | 0.41 ms |
| 10,000 | 93.4 ms | 218.8 ms | 2.0 ms | 381.6 ms | 4.6 ms (0.08 ms after the fix below) | 4.5 ms |

- **Row mapping dominates** from a few hundred events on: 55–68% of a build.
  Of the ~17µs per row, ~11µs is `Time.parse` of `created_at` (`JSON.parse`
  of data and tags is ~1µs each). `Time.iso8601`/`Time.strptime` are 2–3x
  faster; a cheaper timestamp decode is a separate, easy win for every read.
- **The fold is free** (<1%). Snapshots do not exist to save folding; they
  exist to avoid reading and decoding.
- **An empty catch-up read is flat** on PostgreSQL. On SQLite it grew with the
  tag's history because the `event_tags` subquery scanned all of the tag's
  rows before the outer position filter applied; the dialect now repeats the
  position bound inside the subquery (`tags_contain(..., after:)`), which
  takes the 10k-event case from 4.6 ms to 0.08 ms. That change is in this
  branch and benefits every `read_from`, snapshots or not.

## 2. Design

### Snapshots

A snapshot is a projection's state folded through every matching event with
`sequence_position <= P`, stored under a key. Semantics chosen for DCB:

- **Key** = `"#{name}/v#{version}/#{query}"`. The projection's `Query`
  renders its types and tags (`Query[StudentSubscribedToCourse{course:c1}]`),
  so one `Snapshot` configuration covers every entity of a projection and each
  entity gets its own row. `version` invalidates on handler changes.
- **Position** = the position of the build's append condition (`after`).
  Every projection of a build folded everything up to it, so all its
  snapshots are written at the same position, with exactly the states the
  build returned. This is what makes the next build cheap: projections
  sharing a position share one read.
- **Reads** are grouped by snapshot position. `DecisionModel.build` issues
  one read per distinct position (`read_from` after it) over the union of
  that group's queries, plus one from the start for projections without a
  snapshot — over *their* queries only. Results are merged by position. A
  projection over a never-seen entity (the new student in a subscribe
  decision) therefore no longer forces the course's 10,000 events to be
  replayed; the first version of this spike used a single "lowest position"
  read and lost the whole benefit in exactly that case.
- **Condition** = union of all queries, `after` = max(last event read,
  snapshot positions). Every event matching the union at or below that
  position is either in a snapshot or was read, so the guarantee is the same
  as without snapshots.
- **Write policy** `every:` — written when missing, then once the log head
  is at least `every` positions past the snapshot, whether the events in
  between matched or not (the spike counted matching events only, which left
  an idle entity's snapshot behind and let its catch-up read grow; the store
  now exposes `last_position`, taken before the reads, and both the
  condition and the snapshots use it). The upsert is forward-only (a slower
  concurrent builder cannot roll a snapshot back).
- **Stores**: `InMemorySnapshotStore` (Hash + Mutex, no serialization),
  `PostgresSnapshotStore` and `SqliteSnapshotStore` (`projection_snapshots`
  table, JSON state, installed by the backend's `Schema.create!` alongside
  the events; not append-only). `fetch_many` loads all of a build's
  snapshots in one round trip. States that are not JSON-shaped take
  `dump:`/`load:`.

### Materialized streams (spike, not shipped)

The spike's `MaterializedStreams` wrapped a store and kept the decoded
`SequencedEvent`s of every `QueryItem` it had served; the next read of that
item was a `read_from` after the last event held, appended to the stream, and
a multi-item query merged its items' streams. Nothing derived, so nothing
stale in the snapshot sense, but the fold (and the partitioning in
`DecisionModel`) still ran over the whole stream, and the cache was per
process. Measured below, then removed on the strength of the numbers.

### Consistency caveat shared by both

A snapshot position or a materialized stream's last position asserts "every
matching event up to here was visible when read". That holds on SQLite and
`InMemoryStore` (one writer, positions commit in order). On PostgreSQL, two
appends holding disjoint per-tag advisory locks can commit out of sequence
order; the existing append condition already relies on the per-tag locks to
make this safe for the tags a condition names, and snapshots inherit exactly
that reliance — no more, no less. An unconditional append (global lock only)
racing a conditional one on the same tag is the case neither covers; it is
pre-existing and documented here rather than solved.

## 3. Measurements

`examples/snapshot_benchmark.rb`: the course subscription dataset of
`performance.rb` (20,000 students / 100 courses = 100k events, and for
PostgreSQL also 100,000 / 500 = 500k events) plus one course per stream size
with exactly that many subscriptions. Each row is the five-projection
`subscribe_student` decision model on that course, p50 of 50 iterations, in
milliseconds. "warm" = the snapshot or stream already exists.

### DecisionModel.build, SQLite (100k events)

| stream | baseline | snapshot cold | snapshots (db) warm | snapshots (memory) warm | materialized warm (spike) | speedup (db) |
|---:|---:|---:|---:|---:|---:|---:|
| 10 | 0.92 | 1.20 | 0.52 | 0.46 | 0.60 | 1.8x |
| 100 | 3.56 | 3.96 | 0.51 | 0.49 | 1.24 | 6.9x |
| 1,000 | 29.58 | 29.41 | 0.53 | 0.52 | 7.80 | 56x |
| 10,000 | 401.09 | 400.53 | 0.55 | 0.54 | 80.27 | 736x |

### DecisionModel.build, PostgreSQL (100k events)

| stream | baseline | snapshot cold | snapshots (db) warm | snapshots (memory) warm | materialized warm (spike) | speedup (db) |
|---:|---:|---:|---:|---:|---:|---:|
| 10 | 4.16 | 5.46 | 0.65 | 0.51 | 6.62 | 6.4x |
| 100 | 6.90 | 8.26 | 0.65 | 0.56 | 7.17 | 10.6x |
| 1,000 | 39.33 | 40.28 | 0.66 | 0.52 | 12.67 | 60x |
| 10,000 | 340.77 | 322.33 | 0.72 | 0.54 | 74.36 | 476x |

### DecisionModel.build, PostgreSQL (500k events, spike policy)

Measured before the write policy was changed to follow the log head (§3.1);
the warm cells for the smaller courses are the cost of that old policy, not
of the snapshot.

| stream | baseline | snapshot cold | snapshots (db) warm | snapshots (memory) warm | materialized warm (spike) | speedup (db) |
|---:|---:|---:|---:|---:|---:|---:|
| 10 | 6.41 | 7.50 | 7.45 * | 7.31 * | 6.71 | 0.9x |
| 100 | 9.08 | 10.26 | 7.69 * | 9.30 * | 7.70 | 1.2x |
| 1,000 | 45.83 | 45.63 | 6.88 * | 8.95 * | 14.33 | 6.7x |
| 10,000 | 338.56 | 339.54 | 0.59 | 3.93 | 76.74 | 573x |

\* See §3.1: a catch-up read walking the primary key past the events
appended after the snapshot, while the planner's statistics predate them.
With snapshots that follow the head (the shipped policy) the same builds
take ~0.65 ms, as in the 100k table.

### The write loop: build + append with condition, per operation

What an application does: build the decision model, append one event under
its condition, next student. p50 / p99 in ms, 30 operations.

| backend, course | baseline | snapshots every: 1 | every: 10 | every: 100 | materialized (spike) |
|---|---:|---:|---:|---:|---:|
| SQLite, 1,000 subs | 33.2 / 38.8 | 1.6 / 2.6 | 1.8 / 9.8 | 2.1 / 2.9 | 9.7 / 17.5 |
| SQLite, 10,000 subs | 414.5 / 445.6 | 3.2 / 4.0 | 3.4 / 5.3 | 3.8 / 10.9 | 83.5 / 91.9 |
| PostgreSQL 100k, 1,000 subs | 44.9 / 52.2 | 5.2 / 7.0 | 5.3 / 6.5 | 5.0 / 6.8 | 9.5 / 12.0 |
| PostgreSQL 100k, 10,000 subs | 411.0 / 438.0 | 2.6 / 4.0 | 2.5 / 4.1 | 3.1 / 6.6 | 76.6 / 82.0 |
| PostgreSQL 500k, 1,000 subs | 45.9 / 50.1 | 4.5 / 6.6 | 4.5 / 6.8 | 4.9 / 7.4 | 13.0 / 16.1 |
| PostgreSQL 500k, 10,000 subs | 346.9 / 365.4 | 4.6 / 6.1 | 4.7 / 5.7 | 5.1 / 6.3 | 79.7 / 96.2 |

Two things the write loop shows that the read tables cannot:

- The per-entity projections (`student_subs`, `already`) start without a
  snapshot for every new student. With a single "lowest position" read the
  course's whole history was replayed anyway and the write loop gained
  nothing (36 ms vs 42 ms at 1,000 subs in the first version of this spike);
  the grouped reads are what make it 2–4 ms.
- `every:` barely matters at p50 — a snapshot write is one upsert — and shows
  up only as the occasional p99 spike when a rewrite happens. `every: 1`
  keeps the catch-up read shortest and is the right default for decision
  models; a larger value only trades write volume for a longer catch-up
  read.

### 3.1 PostgreSQL: stale statistics and the catch-up read

The starred cells above are not the snapshot's cost. A catch-up read is
`WHERE (items…) AND sequence_position > P ORDER BY sequence_position LIMIT
1000`; the planner can serve it either from the GIN tag index (bitmap scan,
then sort) or by walking the primary key from `P` and filtering. Right after
the benchmark seeds its courses, the table statistics predate those 11,000
events, so `sequence_position > P` is estimated at ~1 row and the primary-key
walk looks free — while it actually filters every event appended after the
snapshot, whatever its tags (~0.5 µs per row). Reproduced in isolation on the
same database:

| catch-up read for a 1,000-event course, 0 matching events after P | plan | p50 |
|---|---|---:|
| statistics current, nothing appended after P | primary key | 0.22 ms |
| 10,000 unrelated events appended after P, statistics stale | primary key, 10,000 rows filtered | 5.37 ms |
| same, after `ANALYZE events` | GIN bitmap | 1.87 ms |

In the spike, a snapshot only moved when the projection folded new events,
so an idle entity's snapshot sat where it was while the log grew past it —
which is what the starred cells show. The shipped policy takes the store's
`last_position` before the reads and rewrites a snapshot once the head is
`every` positions past it, so a catch-up read starts at (or near) the head
and walks nothing; the 100k PostgreSQL table above was measured that way and
is flat at ~0.65 ms. The planner effect itself remains for an entity that is
not rebuilt for a long time: in steady state autoanalyze re-plans after every
`autovacuum_analyze_scale_factor` (10%) of growth, which bounds the walk at
~10% of the table — about 5 ms per 100k events, or ~250 ms on a 5M-event
table right before an autoanalyze. Lower the threshold on the table
(`ALTER TABLE events SET (autovacuum_analyze_scale_factor = 0.01)`) to bound
it tighter. SQLite has no equivalent: its tag subquery carries the position
bound (§1) and the catch-up read stays at 0.08 ms whatever follows the
snapshot.

The same statistics effect explains why PostgreSQL's baseline for the small
courses is 4–7 ms while SQLite's is under 1 ms: each build is at least one
GIN lookup plus a round trip (~0.5–1 ms), and five projections' worth of
per-entity snapshots are loaded in one query, so a warm build on current
statistics is ~1 ms on PostgreSQL versus 0.5 ms on SQLite (§1, "empty
catch-up read").

## 4. Verdict

**Snapshots are worth shipping; materialized streams are not.**

- Snapshots turn a decision model's cost from O(history) into O(new events):
  the write loop on a 10,000-event course goes from 410 ms to 2–5 ms on both
  backends (100–150x), and the read-only build from 340–410 ms to ~0.6 ms.
  Even the 10-event course is 2x (SQLite) to 6x (PostgreSQL) faster warm,
  since a build becomes one snapshot fetch plus one empty read. The first
  build pays the replay it would have paid anyway plus one upsert per
  projection.
- Materialized streams remove the database and decoding work but not the
  fold and partition (~8 µs per event in Ruby): 4–5x at every size, still
  linear, per process, memory-bound, and their per-entity cache misses in
  the write loop make them 3–30x slower than snapshots. They would only make
  sense for a workload that folds the same long streams from one process
  and cannot name its projections — nothing in this gem's examples looks
  like that. Dropped; the numbers stay here as the reason.
- The cheaper win that needs no new concept: row decoding is 55–68% of a
  replay and `Time.parse` is two thirds of that; `Time.iso8601` /
  `Time.strptime` would take ~35% off every read on both backends. Worth
  doing regardless of snapshots.
- What snapshots cost in operations: a `Snapshot` (name, version) per
  projection that wants one, a version bump discipline when handlers change,
  and on PostgreSQL an `autovacuum_analyze_scale_factor` low enough that
  catch-up reads keep their index plan (the `projection_snapshots` table
  comes with `Schema.create!`). Their consistency is exactly the consistency of the append
  condition they are written at — the per-tag advisory lock reasoning in §2
  applies unchanged.

Observability for all of it is in the instrumentation: `decision_model.dcb`
`event_count` (flat when snapshots work), `snapshot.dcb` loads/writes with hit
counts, and the corresponding AppSignal metrics (`dcb.decision_model.events`,
`dcb.snapshot.*`).

## 5. Decisions taken after the spike

- Materialized streams dropped.
- `projection_snapshots` DDL folded into both backends' `Schema.create!`.
- Stores expose `last_position`; a snapshotted build guards up to the log
  head and rewrites snapshots once the head is `every` positions past them,
  so an idle entity's catch-up read no longer grows with the log.
- The `Time.parse` swap in row decoding is a separate change.
- The `autovacuum_analyze_scale_factor` advice stays here (§3.1), with a
  pointer from the README.

Still open: keys are unbounded text (`name/vN/<fingerprint>`); a projection
with a very long `Query` gets a very long key.
