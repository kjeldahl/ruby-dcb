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
- **Tags**: JSON array text column; containment via `json_each` double-NOT-EXISTS.
  Optional later step: `event_tags` index table (GIN equivalent).
- **Types filter**: `type IN (SELECT value FROM json_each(?))` -> fixed param count, mirrors
  PG `= ANY($n::text[])`.
- **Subscribe**: polling. `poll_interval:` option (default 0.1s); check `PRAGMA data_version`
  each tick, only `read_from` when it changed.
- **Schema**: `INTEGER PRIMARY KEY AUTOINCREMENT` (positions never reused, gaps on conflict
  same as BIGSERIAL), `created_at TEXT` ISO8601 ms UTC, append-only triggers, WAL +
  `busy_timeout` set by `Schema.configure!(db)`.
- **Naming**: flat like `InMemoryStore`: `PostgresStore`, `SqliteStore`. Shared abstract
  base `SqlStore`. `Store`/`Schema`/`PgArrayCodec` kept as deprecated aliases.

## Semantic differences vs PG (document in README)
| | PostgresStore | SqliteStore |
|--|--|--|
| append serialization | per-tag advisory locks (parallel non-overlapping) | global (single writer) |
| subscribe wakeup | LISTEN/NOTIFY | poll `data_version` |
| created_at precision | us | ms |
| `:memory:` db | n/a | per-connection; use file DB for multi-conn/subscribe |
| tag lookup | GIN index | scan (or `event_tags` step 8) |

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
tags_contain(n)             # "tags @> $n::text[]" | "NOT EXISTS (SELECT 1 FROM json_each(?) r WHERE NOT EXISTS (SELECT 1 FROM json_each(events.tags) t WHERE t.value = r.value))"
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
| 8 | Optional: `event_tags` index table + benchmark | perf |
| 9 | Examples backend switch, README/CLAUDE.md, CI, mutant subjects | docs/infra |

Each step: `bundle exec rake` + `rubocop` green, one commit.
