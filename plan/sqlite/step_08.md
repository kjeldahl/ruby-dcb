# Step 8: Benchmark record (decision: B, event_tags, taken in steps 4/5)

## Benchmark (sqlite 3.53, WAL, 20 types, 2 tags/event, count query = append condition check)
| events | query | A json_each scan | B event_tags |
|--|--|--|--|
| 200k | tags only | 77 ms | 0.05 ms |
| 200k | type + tags | 9.6 ms | 0.06 ms |
| 1M | tags only | 400 ms | 0.2-0.8 ms |
| 1M | type + tags | 52 ms | 0.2-0.8 ms |
| 1M | insert cost | 30 s | 46 s (+55%, +2 rows/event) |
| 1M | db size | ~165 MB | ~210 MB (+45 MB) |

A is O(rows of matching type) per append condition, inside the serialized write txn ->
throughput ceiling ~20 appends/s at 1M events/type. B is O(matches). Insert overhead of B
is per-tag row inserts; PG pays the same in GIN maintenance.

If chosen: schema + insert go into steps 4/5 directly (not an afterthought); this step
becomes the benchmark record only. Backfill for existing DBs:
`INSERT INTO event_tags SELECT value, sequence_position FROM events, json_each(events.tags)`.

## Why
`json_each` containment scans every row (type index narrows only when types given).
PG has GIN. For tag-scoped conditions on large stores this matters.

## Changes
- Schema: `CREATE TABLE event_tags (sequence_position INTEGER NOT NULL REFERENCES
  events, tag TEXT NOT NULL, PRIMARY KEY (tag, sequence_position)) WITHOUT ROWID;`
  + append-only triggers.
- `SqliteStore#insert_event`: after RETURNING, insert one `event_tags` row per tag
  (same txn). `events.tags` JSON column kept as read-side source of truth.
- `Dialect#tags_contain(n)` ->
  `sequence_position IN (SELECT sequence_position FROM event_tags WHERE tag IN
  (SELECT value FROM json_each(?)) GROUP BY sequence_position HAVING COUNT(*) = ?)`
  -> needs 2 params (list + count): extend dialect to return `[sql, params]`.
- Benchmark: `examples/performance.rb` on both backends before/after; keep only if
  measurable win. Record in `examples/BENCHMARK.md`.

## Done when
- Contract still green; benchmark numbers recorded; decision documented.
