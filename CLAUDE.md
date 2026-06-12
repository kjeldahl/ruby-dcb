# DCB Event Store

Ruby gem implementing the Dynamic Consistency Boundary (DCB) pattern with a PostgreSQL backend.

## Stack
- Ruby >= 3.3, `pg` gem
- Minitest for tests
- SimpleCov for coverage
- Mutant (`mutant-minitest`) for mutation testing

## Project structure
- `lib/dcb_event_store/` - core classes
- `test/unit/` - unit tests
- `test/integration/` - integration tests (require live PG)
- `test/concurrency/` - concurrency tests
- `examples/` - usage examples

## Database
- DB: `dcb_event_store_test`
- Setup: `ruby -e "require_relative 'lib/dcb_event_store'; conn = PG.connect(dbname: 'dcb_event_store_test'); DcbEventStore::Schema.new(conn).create"`

## Running tests
```sh
bundle exec rake test          # all tests
bundle exec ruby test/integration/test_client.rb  # single file
bundle exec mutant run                            # mutation testing (all subjects)
bundle exec mutant run 'DcbEventStore::Store#append'  # single method
```

## Key architecture
- `Event` / `SequencedEvent` - domain event wrappers
- `Query` / `QueryItem` - event stream filtering
- `AppendCondition` - consistency boundary
- `Store` - low-level PG operations
- `InMemoryStore` - single-threaded drop-in for `Store`, for fast tests without PG (shared contract: `test/support/store_contract.rb`)
- `Client` - high-level API (append, read, subscribe)
- `Projection` / `DecisionModel` - higher-level abstractions
- `Upcaster` - event schema migration on read
- `Notifications` / `StoreInstrumentation` / `LogSubscriber` / `RailsLogSubscriber` - observability: pub/sub instrumentation events (`append.dcb`, `read.dcb`, `subscribe.dcb`, `projection.dcb`, `decision_model.dcb`) published through the global `DcbEventStore.instrumentation`; `subscribe.dcb` carries delivery lag, per-event or batched via `subscribe_instrumentation:` store option. `LogSubscriber` is a plain-logger adapter; `RailsLogSubscriber` renders events in ActiveRecord SQL-query style (no Rails dependency); `ActiveSupportInstrumentation` is a drop-in engine routing events through `ActiveSupport::Notifications` (shared engine contract: `test/support/instrumentation_contract.rb`)
