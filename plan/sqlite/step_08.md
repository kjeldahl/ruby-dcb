# Step 8 (optional): event_tags index table

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
