# Step 7: SQLite concurrency, pagination, edge tests

## Tests (`test/sqlite/`)
- `test_concurrent_append.rb`: port PG version. N threads, each own
  `SQLite3::Database` (file DB, WAL, busy_timeout). `test_exactly_one_wins`,
  `test_non_conflicting_all_succeed`. Verifies `BEGIN IMMEDIATE` + busy_timeout.
- `test_store_pagination.rb`: > BATCH_SIZE rows inserted via raw SQL loop in one txn;
  assert complete/ordered/no dupes (or reuse contract version from step 3).
- `test_append_only.rb`: UPDATE/DELETE raise `SQLite3::ConstraintException`.
- Special chars/tags/unicode: covered by contract from step 3; add JSON-specific cases
  (tags containing `"`, `[`, `,`; data with nested arrays).
- Duplicate id inside same batch, empty tags, `:memory:` DB single-conn smoke test.

## Done when
- `bundle exec rake` green incl. new dir (Rakefile glob already `test/**/test_*.rb`).
