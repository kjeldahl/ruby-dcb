# DCB Event Store in Ruby - Implementation Plan

## Context
Implement a DCB-compliant event store gem in Ruby backed by PostgreSQL. DCB (Dynamic Consistency Boundary) is a spec for event stores that enforces consistency via append conditions -- optimistic concurrency checks that fail if conflicting events were appended since the decision model was read. The spec defines: Event (type + data + tags), Query (OR of QueryItems, each with event_types AND tags), AppendCondition (fail_if_events_match query + optional after position), and read/append operations.

## Decisions
- **Ruby 3.3+**, using `Data.define` for value objects
- **Minitest** for tests
- **Raw `pg` gem** -- no ORM. SQL surface is small and needs advisory locks + array operators
- **Global advisory lock** for append atomicity (simple, correct, optimize later)
- **Core + Projection DSL** -- include Projection/DecisionModel helpers but keep Store usable standalone

## Database Schema

```sql
CREATE TABLE events (
  sequence_position BIGSERIAL PRIMARY KEY,
  type              TEXT NOT NULL,
  data              JSONB NOT NULL DEFAULT '{}',
  tags              TEXT[] NOT NULL DEFAULT '{}',
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_events_type ON events (type);
CREATE INDEX idx_events_tags ON events USING GIN (tags);
```

Tags as `text[]` with GIN index. `@>` operator maps directly to DCB's "must contain ALL tags" semantics.

## Project Structure

```
lib/
  dcb_event_store.rb                    # namespace, top-level require
  dcb_event_store/
    version.rb
    event.rb                            # Event = Data.define(:type, :data, :tags)
    sequenced_event.rb                  # SequencedEvent = Data.define(:sequence_position, :type, :data, :tags, :created_at)
    query.rb                            # Query, QueryItem
    append_condition.rb                 # AppendCondition = Data.define(:fail_if_events_match, :after)
    store.rb                            # Store#read(query), Store#append(events, condition)
    schema.rb                           # Schema.create!(conn), Schema.drop!(conn)
    projection.rb                       # Projection class (initial_state, handlers, query)
    decision_model.rb                   # DecisionModel.build(store, projections_hash) -> {states, condition}
test/
  test_helper.rb
  support/database.rb                   # test DB setup/teardown, per-test truncation
  unit/
    test_event.rb
    test_query.rb
    test_projection.rb
  integration/
    test_store_read.rb
    test_store_append.rb
  concurrency/
    test_concurrent_append.rb
```

## Design Notes
- **Tags**: Freeform strings allowed (no validation). Convention is `prefix:value` but not enforced.
- **Store#read**: Returns an `Enumerator` for streaming. Fetches in batches internally (e.g. 1000 rows) so callers can `.each` without loading all events into memory.
- **Gem name**: `dcb_event_store`

## Steps
- **Phase 1** (core): `step_01.md` through `step_10.md`
- **Phase 2** (hardening + features): `step_11.md` through `step_17.md`
