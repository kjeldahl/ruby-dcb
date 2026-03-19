# Step 17: Upcaster & Client

## Goal
Two features: (1) transform event data on read to handle schema evolution, (2) convenience wrapper that auto-wires causation/correlation IDs.

## Changes

### Upcaster
- New class `Upcaster` with `register(event_type, from_version:, &block)` and `upcast(type, data, version)`
- Transformers keyed by `[type, version]`, chained until no match
- Returns `[transformed_data, final_version]`

### Schema
- Add `schema_version INTEGER NOT NULL DEFAULT 1` column to events table

### SequencedEvent
- Add `schema_version` field

### Store
- Accept optional `upcaster:` in constructor
- Apply upcaster in `row_to_sequenced_event` when present
- Insert `schema_version` (always 1 for new events)

### Client
- New class `Client` wrapping Store
- Constructor: `initialize(store, correlation_id: nil, causation_id: nil)` -- auto-generates correlation_id
- `append(events, condition)` -- stamps events with causation/correlation IDs
- `read(query)`, `read_from(query, after:)` -- delegates to store
- `caused_by(event)` -- returns new Client with `causation_id: event.id`, preserving correlation chain

## Tests

### Upcaster (unit)
- Single-version transform
- Chained transforms (v1 -> v2 -> v3)
- Unknown type/version returns data unchanged

### Upcaster (integration)
- Store with upcaster reads old events with transformed data + bumped version

### Client (unit)
- Auto-generates correlation_id
- Stamps events with causation/correlation
- `caused_by` chains correctly

### Client (integration)
- Round-trip: events persisted with correct IDs
- Caused_by wiring through store

## Done When
- Upcaster chains transforms on read
- Client auto-wires traceability IDs
- `bundle exec rake` green (77 tests, 139 assertions)
