# Performance Experiments — Design Spec

## Goal

Instrument the append path to identify the actual bottleneck, then test
five optimization ideas in isolation against a consistent baseline.

## Phase 1: Instrumentation

Add timing probes to Store#append and DecisionModel.build:

| Probe | Measures |
|-------|----------|
| dm_read | DecisionModel.build — combined query read + fold |
| lock_wait | pg_advisory_xact_lock(0) acquisition |
| condition_check | COUNT query for conflict detection |
| insert | INSERT statement(s) |
| notify_commit | NOTIFY + COMMIT |
| total | End-to-end append (lock through commit) |

Implementation: `Store::Instrumented` subclass that wraps Store methods
with timing. No changes to production code.

## Phase 2: Experiments

Each measured in isolation against same baseline (100k students, 500 courses):

1. **EXISTS vs COUNT** — `SELECT EXISTS(... LIMIT 1)` instead of `SELECT COUNT(*)`
2. **Per-tag advisory locks** — hash query tags to lock key instead of global 0
3. **Single-statement CTE** — combine condition + insert in one SQL round-trip
4. **Read outside lock** — verify/ensure DM read is outside transaction
5. **Optimistic skip-lock** — `pg_try_advisory_xact_lock` + retry loop

## Methodology

- Single branch, isolated experiments (reset between each)
- Same benchmark parameters: 100k students, 500 courses, 50 iterations
- Journal records: baseline, each experiment's results, analysis
