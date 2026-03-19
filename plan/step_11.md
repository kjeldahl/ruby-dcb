# Step 11: Event ID (UUID)

## Goal
Give every event a unique UUID identity so events can be referenced individually, enabling idempotent writes and traceability.

## Changes

### Schema
- Add `event_id UUID NOT NULL DEFAULT gen_random_uuid()` column to `events` table
- Add unique index `idx_events_event_id` on `event_id`

### Event value object
- Add `id` field (default `SecureRandom.uuid`)

### SequencedEvent
- Add `id` field, populated from `event_id` column on read

### Store
- Insert `event_id` from `event.id` on append
- Map `row["event_id"]` to `id` on read

## Tests
- Event auto-generates UUID when none given
- Custom id preserved through append/read round-trip
- SequencedEvent includes id from persisted event

## Done When
- Every event has a UUID on write and read
- Existing tests updated to include `id` field
- `bundle exec rake` green