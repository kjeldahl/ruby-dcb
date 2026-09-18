# DCB Event Store

Ruby gem implementing the Dynamic Consistency Boundary (DCB) pattern with PostgreSQL and SQLite backends.

## Stack
- Ruby >= 3.3; `pg` and `sqlite3` are optional (dev) dependencies - an application adds the driver for the backend it uses
- Minitest for tests
- SimpleCov for coverage
- Mutant (`mutant-minitest`) for mutation testing

## Project structure
- `lib/dcb_event_store/` - core classes
- `lib/dcb_event_store/sql_store/` - collaborators shared by SQL backends (`SqlBuilder`, `RowMapper`)
- `lib/dcb_event_store/postgres_store/` - PG-only collaborators (`Schema`, `Dialect`, `ArrayCodec`, `LockKeys`)
- `lib/dcb_event_store/sqlite_store/` - SQLite-only collaborators (`Schema`, `Dialect`)
- `test/unit/` - unit tests
- `test/integration/` - integration tests (require live PG); backend-neutral cases live in the shared contracts, so these files keep only PG specifics (append-only triggers, LISTEN/NOTIFY subscribe, `text[]` round trip) plus the PG contract runners
- `test/sqlite/` - SQLite backend tests, no server needed: `test_sqlite_store.rb` (contract runner plus transaction and JSON-encoding specifics), `test_schema.rb` (DDL, append-only triggers, `configure!` pragmas, `:memory:` smoke test), `test_subscribe.rb` (polling subscribe, ported from the PG file) and `test_concurrent_append.rb` (racing connections on one file database)
- `test/concurrency/` - concurrency tests
- `test/support/` - shared test infra: `postgres_database.rb` (`PostgresDatabaseHelper`: connection, schema, `build_store`), `sqlite_database.rb` (`SqliteDatabaseHelper`: tempfile database, schema, `build_store`, extra connections) and the backend contracts `store_contract.rb` (append/read/read_from/pagination/instrumentation), `special_characters_contract.rb`, `client_contract.rb`, `decision_model_contract.rb`, `upcaster_contract.rb`, plus `in_memory_equivalence_contract.rb` (same scripted operations on the backend and on InMemoryStore, results compared). Each contract is a module run against every backend: PG via `test/integration/`, SQLite via `test/sqlite/test_sqlite_store.rb`, InMemory via `test/unit/test_in_memory_store.rb`. Including classes set `@store` in setup and define `build_store(upcaster: nil)`
- `examples/` - usage examples

## Database
- PostgreSQL DB: `dcb_event_store_test`
- Setup: `ruby -Ilib -rpg -e "require 'dcb_event_store'; DcbEventStore::PostgresStore::Schema.create!(PG.connect(dbname: 'dcb_event_store_test'))"`
- SQLite needs no setup: the tests create a throwaway database file per test (`SqliteDatabaseHelper`), and `SqliteStore::Schema.create!(db)` installs the schema and the connection pragmas

## Running tests
```sh
bundle exec rake test          # all tests
bundle exec ruby test/integration/test_client.rb  # single file
bundle exec mutant run                            # mutation testing (all subjects)
bundle exec mutant run 'DcbEventStore::SqlStore#append'  # single method
```

## Key architecture
- `Event` / `SequencedEvent` - domain event wrappers
- `Query` / `QueryItem` - event stream filtering
- `AppendCondition` - consistency boundary
- `SqlStore` - abstract base for SQL backends: instrumentation, paginated read, append orchestration, subscribe loop; subclasses implement the hooks (`with_write_transaction`, `acquire_locks!`, `count_matching`, `insert_event`, `fetch_batch`, `notify_appended`, `listen`/`unlisten`/`wait_for_append`)
- `PostgresStore` - low-level PG operations (advisory locks, single-statement conditional append, LISTEN/NOTIFY). Was named `Store`; `Store` is kept as an alias
- `SqliteStore` - low-level SQLite operations: appends run in `BEGIN IMMEDIATE` (single writer database-wide, so the consistency check needs no extra locking), tags are indexed in a separate `event_tags(tag, sequence_position)` table standing in for PG's GIN index, and `subscribe` polls instead of using LISTEN/NOTIFY: `wait_for_append` sleeps `poll_interval:` (default 0.1s) until either `PRAGMA data_version` moved (another connection committed) or the connection's own `total_changes` moved (a store that appends and subscribes over one connection), then the shared loop reads from the last delivered position. A subscriber normally holds its own connection on the same file; `:memory:` cannot be shared. `Schema.configure!` sets WAL and a GVL-releasing busy handler (`busy_handler_timeout=`), without which a thread waiting for the write lock would starve the thread holding it
- `<Backend>Store::Dialect` - per-backend SQL details injected into `SqlBuilder`/`RowMapper` (placeholders, type/tag matching, insert casts, tag list encoding); `PostgresStore::Dialect` encodes lists through `PostgresStore::ArrayCodec` (was `PgArrayCodec`, kept as an alias)
- `InMemoryStore` - single-threaded drop-in for `PostgresStore`, for fast tests without PG (runs the same shared contracts: `test/support/*_contract.rb`)
- `Client` - high-level API (append, read, subscribe)
- `Projection` / `DecisionModel` - higher-level abstractions
- `Upcaster` - event schema migration on read
- `Notifications` / `StoreInstrumentation` / `LogSubscriber` / `RailsLogSubscriber` - observability: pub/sub instrumentation events (`append.dcb`, `read.dcb`, `subscribe.dcb`, `projection.dcb`, `decision_model.dcb`) published through the global `DcbEventStore.instrumentation`; `subscribe.dcb` carries delivery lag, per-event or batched via `subscribe_instrumentation:` store option. `LogSubscriber` is a plain-logger adapter; `RailsLogSubscriber` renders events in ActiveRecord SQL-query style (no Rails dependency); `ActiveSupportInstrumentation` is a drop-in engine routing events through `ActiveSupport::Notifications` (shared engine contract: `test/support/instrumentation_contract.rb`); `AppsignalSubscriber` maps events to AppSignal custom metrics (lazy require, engine-agnostic)
