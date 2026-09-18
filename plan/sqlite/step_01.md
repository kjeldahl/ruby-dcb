# Step 1: Extract SqlStore base, rename Store -> PostgresStore

## Goal
Split `Store` into backend-neutral `SqlStore` (template) + `PostgresStore` (PG primitives).
Zero behavior change.

## Changes
- `lib/dcb_event_store/sql_store.rb` (new): from `store.rb` move `BATCH_SIZE`, `read`,
  `read_from`, `append` orchestration, `paginated_read`, instrumentation include,
  `subscribe_instrumentation` handling. Define abstract hooks (see overview) raising
  `NotImplementedError`.
- `lib/dcb_event_store/postgres_store.rb` (new): `class PostgresStore < SqlStore`;
  implements hooks with `@conn`, `SqlBuilder`, `LockKeys`, `PgArrayCodec`.
  - `append`: replace CTE with check-then-insert? **No** - keep CTE in PG for now via
    override of `append_with_condition`; base default = check-then-insert. Revisit in
    step 8 benchmark. (Keeps PG diff minimal, mutant surface unchanged.)
- Move `store/{sql_builder,row_mapper}.rb` -> `sql_store/`, namespace `SqlStore::`.
  `store/lock_keys.rb` -> `postgres_store/lock_keys.rb`, `PostgresStore::LockKeys`.
- `lib/dcb_event_store/store.rb`: `Store = PostgresStore` (+ `Store::SqlBuilder` etc.
  aliases for old constants). No warn yet (tests reference them heavily).
- Instrumentation `store:` payload becomes `"DcbEventStore::PostgresStore"`; update
  README examples + tests asserting the name.

## Tests
- Rename `test/integration/test_store_*` cover strings to `PostgresStore`.
- `.mutant.yml`: `Store::SqlBuilder*` -> `SqlStore::SqlBuilder*`, `Store::LockKeys*` ->
  `PostgresStore::LockKeys*`.

## Done when
- `bundle exec rake`, `rubocop`, `mutant run` (changed subjects) green.
- `DcbEventStore::Store.new(conn)` still works.
