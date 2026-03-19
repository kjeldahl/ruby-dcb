# Step 14: Append-Only Immutability

## Goal
Enforce at the database level that events cannot be updated or deleted. The event log is strictly append-only.

## Changes

### Schema
- Create PL/pgSQL function `prevent_event_mutation()` that raises an exception on UPDATE or DELETE
- Create trigger `enforce_append_only` BEFORE UPDATE OR DELETE on events, FOR EACH ROW
- Use `DROP TRIGGER IF EXISTS` + `CREATE TRIGGER` for idempotent schema setup

### Test cleanup
- TRUNCATE (DDL, not DML) still works -- bypasses row-level triggers
- Tests continue using `TRUNCATE events RESTART IDENTITY`

## Tests
- UPDATE raises PG::RaiseException
- DELETE raises PG::RaiseException
- TRUNCATE still works (for test cleanup)
- Normal INSERT still works

## Done When
- DB rejects any UPDATE or DELETE on events table
- Test suite still cleans up via TRUNCATE
- `bundle exec rake` green
