# Step 13: Causation & Correlation IDs

## Goal
Optional traceability columns linking events to their cause and broader workflow.

## Changes

### Schema
- Add `causation_id UUID` (nullable) column
- Add `correlation_id UUID` (nullable) column
- Add index `idx_events_correlation_id` on `correlation_id`

### Event value object
- Add `causation_id` and `correlation_id` fields (default `nil`)

### SequencedEvent
- Add `causation_id` and `correlation_id` fields

### Store
- Insert causation/correlation on append
- Map from row on read

## Tests
- Event accepts optional causation_id/correlation_id
- Values round-trip through append/read
- nil when not provided

## Done When
- Causation/correlation IDs flow end-to-end
- `bundle exec rake` green
