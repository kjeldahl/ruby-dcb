# Step 2: Dialect extraction

## Goal
Make `SqlBuilder` and `RowMapper` backend-neutral by injecting a dialect.

## Changes
- `postgres_store/dialect.rb`: `PostgresStore::Dialect` implements interface in overview.
  Owns `ArrayCodec` (moved from `pg_array_codec.rb`; `PgArrayCodec` alias kept).
- `sql_store/sql_builder.rb`: `initialize(dialect)`. Replace hardcoded `$n`, `ANY`, `@>`,
  casts with dialect calls. `values_clause` uses `dialect.insert_row(offset)`.
- `sql_store/row_mapper.rb`: `initialize(dialect, upcaster)`; tags via
  `dialect.decode_list`. `Integer(row["sequence_position"])` tolerates Integer or String.
  `created_at`: `Time.parse` if String, else as-is.
- Move `test/unit/test_pg_array_codec.rb` -> `test_postgres_dialect.rb` (+ new dialect
  cases). `test_sql_builder.rb` runs with `PostgresStore::Dialect.new`, asserts SQL
  unchanged byte-for-byte vs current expectations.

## Mutant
- Subjects: `SqlStore::SqlBuilder*`, `PostgresStore::Dialect*`, `PostgresStore::ArrayCodec*`.

## Done when
- All green; generated PG SQL identical to before (existing unit tests prove it).
