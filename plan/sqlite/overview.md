# SQLite Backend - Implementation Plan

## Context
Today: `Store` (PostgreSQL, full), `InMemoryStore` (single-threaded, tests). Goal: full
SQLite backend (`SqliteStore`) with same contract, plus refactorings so backends share
logic instead of duplicating it.

Verified on SQLite 3.53 / `sqlite3` gem 2.9.6: `INSERT ... ON CONFLICT DO NOTHING RETURNING`,
`json_each` tag containment, `RAISE(ABORT)` triggers, `PRAGMA data_version`,
`BEGIN IMMEDIATE` serializes concurrent writers (10 racing conns -> exactly 1 winner).

## Decisions
- **Gem**: `sqlite3` (>= 2.0, bundles SQLite >= 3.45). Min SQLite 3.35 (RETURNING).
- **Deps**: `pg` and `sqlite3` both *optional* runtime deps (lazy `require` inside backend
  files, listed as dev deps only). README: "add `pg` or `sqlite3` to your Gemfile".
- **Locking**: no advisory locks. `BEGIN IMMEDIATE` = single writer DB-wide -> condition
  check + inserts atomic by construction. `LockKeys` stays PG-only.
- **Append**: plain check-then-insert inside `BEGIN IMMEDIATE` (no CTE trick needed).
  Per-row `INSERT ... ON CONFLICT(event_id) DO NOTHING RETURNING`.
- **Tags**: JSON array text column on `events` (read side) + `event_tags(tag, sequence_position)`
  index table (query side, GIN equivalent). Containment: `sequence_position IN (SELECT
  sequence_position FROM event_tags WHERE tag IN (SELECT value FROM json_each(?)) GROUP BY
  sequence_position HAVING COUNT(*) = ?)`.
- **Types filter**: `type IN (SELECT value FROM json_each(?))` -> fixed param count, mirrors
  PG `= ANY($n::text[])`.
- **Subscribe**: polling. `poll_interval:` option (default 0.1s); check `PRAGMA data_version`
  each tick, only `read_from` when it changed.
- **Schema**: `INTEGER PRIMARY KEY AUTOINCREMENT` (positions never reused, gaps on conflict
  same as BIGSERIAL), `created_at TEXT` ISO8601 ms UTC, append-only triggers, WAL +
  `busy_timeout` set by `Schema.configure!(db)`.
- **Naming**: flat like `InMemoryStore`: `PostgresStore`, `SqliteStore`. Shared abstract
  base `SqlStore`. `Store`/`Schema`/`PgArrayCodec` kept as deprecated aliases.

## Confirmed decisions (2026-09-18)
- `pg`/`sqlite3` both user-supplied (dev deps only in gemspec). Confirmed.
- Rename `Store` -> `PostgresStore` (+ deprecated alias). Confirmed.
- Gem `sqlite3`. Confirmed. Min SQLite 3.35. Confirmed.
- Poll interval default 0.1s. Confirmed.
- Neutral PG integration tests move to shared contracts (step 3). Confirmed.
- Examples via `DCB_BACKEND`. Confirmed.
- Tag storage: **B** `event_tags` index table from the start (steps 4/5). Benchmark in step_08.

## Semantic differences vs PG (document in README)
| | PostgresStore | SqliteStore |
|--|--|--|
| append serialization | per-tag advisory locks (parallel non-overlapping) | global (single writer) |
| subscribe wakeup | LISTEN/NOTIFY | poll `data_version` |
| created_at precision | us | ms |
| `:memory:` db | n/a | per-connection; use file DB for multi-conn/subscribe |
| tag lookup | GIN index | `event_tags` table |

## Target layout
```
lib/dcb_event_store/
  sql_store.rb                 # abstract base: instrumentation, paginated read, append
                               # orchestration, subscribe loop. Hooks below.
  sql_store/sql_builder.rb     # dialect-parametrized (moved from store/)
  sql_store/row_mapper.rb      # tag decoder injected (moved from store/)
  postgres_store.rb            # < SqlStore; PG conn, advisory locks, LISTEN/NOTIFY
  postgres_store/schema.rb, dialect.rb, lock_keys.rb, array_codec.rb
  sqlite_store.rb              # < SqlStore; BEGIN IMMEDIATE, polling
  sqlite_store/schema.rb, dialect.rb
  in_memory_store.rb           # unchanged
  store.rb                     # compat aliases (Store, Schema, PgArrayCodec) + warn
```

### SqlStore hooks (subclass must implement)
```ruby
with_write_transaction(&)        # PG: BEGIN/COMMIT; SQLite: BEGIN IMMEDIATE/COMMIT
acquire_locks!(condition)        # PG: advisory; SQLite: no-op
count_matching(query, after)     # Integer
insert_event(event) -> row|nil   # nil on duplicate id
fetch_batch(query, after, limit) # Array<Hash> string keys
notify_appended(position)        # PG: NOTIFY; SQLite: no-op
wait_for_append                  # PG: wait_for_notify; SQLite: sleep+data_version
listen / unlisten                # PG only; default no-op
```
`SqlStore#append` = `with_write_transaction { acquire_locks!; raise ConditionNotMet if
condition && count_matching > 0; events.filter_map { insert_event }; notify_appended }`.
PG keeps its CTE variant by overriding `append_with_condition` only if benchmark shows
regression (step 1 verifies).

### Dialect interface (pure, mutant subject)
```ruby
placeholder(n)              # "$n" | "?"
type_in(n)                  # "type = ANY($n::text[])" | "type IN (SELECT value FROM json_each(?))"
tags_contain(tags, params)  # appends its params, returns clause. PG: "tags @> $n::text[]" (1 param).
                            # SQLite: event_tags subquery (2 params: json list, count)
encode_list(arr) / decode_list(str)   # PG array literal | JSON array
insert_casts                # "::uuid, ::jsonb, ..." | none
```

## Steps
| # | Step | Behavior change |
|--|--|--|
| 1 | Extract `SqlStore` base, `Store` -> `PostgresStore` + alias | none |
| 2 | Dialect extraction: `SqlBuilder(dialect)`, `RowMapper(decoder)` | none |
| 3 | Test infra: `PostgresDatabaseHelper`, move backend-neutral tests to contracts | none |
| 4 | `sqlite3` dep, `SqliteStore::Schema` | new |
| 5 | `SqliteStore::Dialect` + `SqliteStore` read/append; StoreContract green | new |
| 6 | Subscribe: base loop + `wait_for_append`; SQLite polling | PG refactor, SQLite new |
| 7 | SQLite concurrency, pagination, append-only, subscribe tests | tests |
| 8 | Benchmark PG vs SQLite, record in BENCHMARK.md | docs |
| 9 | Examples backend switch, README/CLAUDE.md, CI, mutant subjects | docs/infra |

Each step: `bundle exec rake` + `rubocop` green, one commit.

## Status
| # | Step | Status |
|--|--|--|
| 1 | `SqlStore` base, `Store` -> `PostgresStore` | done, 51de433 |
| 2 | Dialect extraction | done, 32df965 |
| 3 | Test infra + shared contracts | done, 87f81b3 |
| 4 | `sqlite3` dep, `SqliteStore::Schema` | done, 7268b65 (with step 5) |
| 5 | `SqliteStore::Dialect` + read/append | done, 7268b65 |
| 6 | Subscribe loop + SQLite polling | done, 890e728 (with step 7) |
| 7 | SQLite concurrency/pagination/trigger/subscribe tests | done, 890e728 |
| 8 | Benchmark record | done, 2758f19 |
| 9 | Examples, docs, CI, mutant | done, 2758f19 (examples) + the docs commit after it |

## Deviations from the plan
- PostgreSQL keeps its single-statement CTE append (`append_with_condition`
  override); only SQLite uses the base check-then-insert (step 1).
- SQLite waits with `SQLite3::Database#busy_handler_timeout=`, not SQLite's own
  `busy_timeout` pragma: the C handler sleeps holding the GVL, which starves
  the thread that must commit (step 4).
- `wait_for_append` compares `PRAGMA data_version` *and* the connection's
  `total_changes`; data_version alone never moves for a store that appends and
  subscribes over one connection (step 6).
- `SqliteStore*` is not a mutant subject: measured 98.34% (9 of 543 alive), all
  equivalent edits. Reasoning recorded in `.mutant.yml` (steps 7, 9).
- Step 3 deleted `test/integration/test_store_append.rb`, `test_read_from.rb`,
  `test_special_char_tags.rb` and `test/edge_cases/test_special_characters.rb`
  instead of rewriting them: their cases moved into the contracts under
  `test/support/`, which every backend now runs.
- `examples/performance.rb` runs on the two SQL backends and refuses
  `DCB_BACKEND=memory` (whole-log scans per read, no cross-process sharing)
  rather than running `DCB_BACKEND=all` in one process (step 9).
- The deprecated aliases warn through `Module#deprecate_constant`, so the
  warning is Ruby's and appears per reference when the deprecation category is
  enabled, instead of a hand-rolled once-per-process `Kernel#warn` (step 9).
