# DCB Event Store

Ruby gem implementing the Dynamic Consistency Boundary (DCB) pattern with a PostgreSQL backend.

## Stack
- Ruby >= 3.3, `pg` gem
- Minitest for tests
- SimpleCov for coverage
- Mutant (`mutant-minitest`) for mutation testing

## Project structure
- `lib/dcb_event_store/` - core classes
- `lib/dcb_event_store/sql_store/` - collaborators shared by SQL backends (`SqlBuilder`, `RowMapper`)
- `lib/dcb_event_store/postgres_store/` - PG-only collaborators (`Dialect`, `ArrayCodec`, `LockKeys`)
- `test/unit/` - unit tests
- `test/integration/` - integration tests (require live PG); backend-neutral cases live in the shared contracts, so these files keep only PG specifics (append-only triggers, LISTEN/NOTIFY subscribe, `text[]` round trip) plus the PG contract runners
- `test/concurrency/` - concurrency tests
- `test/support/` - shared test infra: `postgres_database.rb` (`PostgresDatabaseHelper`: connection, schema, `build_store`) and the backend contracts `store_contract.rb` (append/read/read_from/pagination/instrumentation), `special_characters_contract.rb`, `client_contract.rb`, `decision_model_contract.rb`, `upcaster_contract.rb`. Each contract is a module run against every backend: PG via `test/integration/`, InMemory via `test/unit/test_in_memory_store.rb`. Including classes set `@store` in setup and define `build_store(upcaster: nil)`
- `examples/` - usage examples

## Database
- DB: `dcb_event_store_test`
- Setup: `ruby -e "require_relative 'lib/dcb_event_store'; conn = PG.connect(dbname: 'dcb_event_store_test'); DcbEventStore::Schema.new(conn).create"`

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
- `<Backend>Store::Dialect` - per-backend SQL details injected into `SqlBuilder`/`RowMapper` (placeholders, type/tag matching, insert casts, tag list encoding); `PostgresStore::Dialect` encodes lists through `PostgresStore::ArrayCodec` (was `PgArrayCodec`, kept as an alias)
- `InMemoryStore` - single-threaded drop-in for `PostgresStore`, for fast tests without PG (runs the same shared contracts: `test/support/*_contract.rb`)
- `Client` - high-level API (append, read, subscribe)
- `Projection` / `DecisionModel` - higher-level abstractions
- `Upcaster` - event schema migration on read
- `Notifications` / `StoreInstrumentation` / `LogSubscriber` / `RailsLogSubscriber` - observability: pub/sub instrumentation events (`append.dcb`, `read.dcb`, `subscribe.dcb`, `projection.dcb`, `decision_model.dcb`) published through the global `DcbEventStore.instrumentation`; `subscribe.dcb` carries delivery lag, per-event or batched via `subscribe_instrumentation:` store option. `LogSubscriber` is a plain-logger adapter; `RailsLogSubscriber` renders events in ActiveRecord SQL-query style (no Rails dependency); `ActiveSupportInstrumentation` is a drop-in engine routing events through `ActiveSupport::Notifications` (shared engine contract: `test/support/instrumentation_contract.rb`); `AppsignalSubscriber` maps events to AppSignal custom metrics (lazy require, engine-agnostic)
