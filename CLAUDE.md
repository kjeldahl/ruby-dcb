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
- `Client` - high-level API (append, read, subscribe)
- `Projection` / `DecisionModel` - higher-level abstractions
- `Upcaster` - event schema migration on read
