# Step 9: Examples, docs, CI, mutant

## Changes
- `examples/support/backend.rb`: `Backend.build(ENV.fetch("DCB_BACKEND", "postgres"))`
  -> `[store, cleanup]` for `postgres | sqlite | memory`. Replace the duplicated
  `PG.connect ... TRUNCATE` block in each example. `examples/performance.rb` runs
  both SQL backends when `DCB_BACKEND=all`.
- README: Requirements (PG **or** SQLite), Setup, "Choosing a backend" section with
  semantic-differences table from overview, `SqliteStore` usage, subscribe polling note,
  `:memory:` caveat. Replace `Store.new(conn)` with `PostgresStore.new(conn)`.
- CLAUDE.md: stack, layout (`sql_store/`, `postgres_store/`, `sqlite_store/`,
  `test/sqlite/`), key architecture entries.
- `store.rb` compat aliases: add `Kernel#warn` deprecation once per process
  (`Store`, `Schema`, `PgArrayCodec`). Remove `DatabaseHelper` alias.
- CI (`ci.yml`): `sqlite3` needs no service; `bundle exec ruby -Itest -e 'Dir["test/sqlite/**/test_*.rb"].each { require _1 }'`
  step runs without PG to prove independence; full `rake` still runs everything.
- `.mutant.yml`: add requires for `test/sqlite/*`, `test/unit/test_*dialect*`; subjects
  `SqliteStore*` (fast, no server -> unlike PG, mutable), `SqliteStore::Dialect*`,
  `PostgresStore::Dialect*`. Keep `PostgresStore*`/`RowMapper` excluded as today.
- gemspec summary: "DCB-compliant event store backed by PostgreSQL or SQLite".

## Done when
- CI green on 3.3/3.4/4.0; mutant incremental job green; README examples run for
  all three `DCB_BACKEND` values.
