# Step 3: Test infrastructure for multiple backends

## Goal
One contract, N backends. Reduce PG-only test files to genuinely PG-specific cases.

## Changes
- `test/support/database.rb` -> `test/support/postgres_database.rb`
  (`PostgresDatabaseHelper`, `setup_db` builds `PostgresStore`). Keep `DatabaseHelper`
  alias until step 9.
- Audit `test/integration/test_store_append.rb`, `test_store_read.rb`, `test_read_from.rb`,
  `test_client.rb`, `test_decision_model.rb`, `test_upcaster_integration.rb`,
  `test/edge_cases/test_special_characters.rb`, `test_special_char_tags.rb`: any case not
  touching PG specifics moves into `test/support/store_contract.rb` (or new
  `client_contract.rb`, `decision_model_contract.rb`). Delete duplicates.
- PG-specific stays: advisory locks, LISTEN/NOTIFY, `text[]` roundtrip, pagination via
  `generate_series` (rewrite pagination to use `store.append` in a loop -> contract-able).
- `test/unit/test_in_memory_store.rb` picks up new contract cases (may expose InMemory
  gaps -> fix).

## Done when
- Contract runs green on PG + InMemory. Total assertions >= before.
