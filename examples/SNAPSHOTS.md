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
- **Write policy** `every:` — written when missing, then once a build folded
  at least `every` events on top of the snapshot. The upsert is forward-only
  (a slower concurrent builder cannot roll a snapshot back).
- **Stores**: `InMemorySnapshotStore` (Hash + Mutex, no serialization),
  `PostgresSnapshotStore` and `SqliteSnapshotStore` (`projection_snapshots`
  table, JSON state, own `Schema.create!`; separate from the events schema and
  not append-only). `fetch_many` loads all of a build's snapshots in one round
  trip. States that are not JSON-shaped take `dump:`/`load:`.

### Materialized streams

`MaterializedStreams` wraps a store and keeps the decoded `SequencedEvent`s of
every `QueryItem` it has served; the next read of that item is a `read_from`
after the last event held, appended to the stream. A multi-item query merges
its items' streams. Nothing is derived, so nothing can be stale in the
snapshot sense, but the fold (and the partitioning in `DecisionModel`) still
runs over the whole stream, and the cache is per process.

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

_Filled in from `examples/snapshot_benchmark.rb` runs — see below._
