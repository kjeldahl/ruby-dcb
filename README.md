# dcb_event_store

A Ruby implementation of the [Dynamic Consistency Boundary (DCB)](https://dcb.events) event store pattern, backed by PostgreSQL or SQLite.

DCB is an alternative to stream-based event stores. Instead of partitioning events into streams with per-stream optimistic concurrency, DCB uses **tags** to define dynamic consistency boundaries and **append conditions** for cross-entity optimistic concurrency checks. A single event can belong to multiple consistency boundaries through its tags.

## Requirements

- Ruby >= 3.3
- A driver for the backend you use, added to **your** Gemfile — the gem depends on neither:
  - [`pg`](https://rubygems.org/gems/pg) for PostgreSQL (`PostgresStore`)
  - [`sqlite3`](https://rubygems.org/gems/sqlite3) >= 2.0 for SQLite (`SqliteStore`), which bundles SQLite >= 3.45; SQLite >= 3.35 is the minimum (`RETURNING`)

Each backend file loads its driver lazily, so an application that only uses one never needs the other installed. The backend classes and their collaborators are themselves loaded on first reference, so an application only loads the backend it constructs.

## Setup

```ruby
# Gemfile
gem "dcb_event_store"
gem "pg"        # for PostgresStore
gem "sqlite3"   # for SqliteStore
```

PostgreSQL needs a database; the schema is installed by the gem:

```bash
createdb my_event_store
```

```ruby
conn = PG.connect(dbname: "my_event_store")
DcbEventStore::PostgresStore::Schema.create!(conn)
```

SQLite needs no setup beyond a path — `create!` installs the schema and the connection pragmas (WAL, busy handler) the store expects:

```ruby
db = SQLite3::Database.new("events.sqlite3")
DcbEventStore::SqliteStore::Schema.create!(db)
```

Both are idempotent (`CREATE TABLE IF NOT EXISTS`), so they can run at boot. `Schema.configure!(db)` alone applies the pragmas to a further SQLite connection on an existing database.

### The store owns its connection

**A connection handed to a store belongs to that store**, and must not also carry application queries. The store configures it and holds state on it:

- `PostgresStore` replaces the connection's **result type map** so `TIMESTAMPTZ` is decoded by the driver, keeps it in `LISTEN` for the duration of a `subscribe`, and holds advisory locks and transactions on it during an append.
- `SqliteStore` relies on the pragmas `Schema.create!`/`configure!` set (WAL, foreign keys, busy handler, hash rows), and appends in `BEGIN IMMEDIATE` transactions.

Sharing one connection between a store and your own queries means your results get decoded by the store's type map, and your statements land inside its transactions. Give the application its own connection, and each concurrent store its own.

## Choosing a backend

Both backends implement the same API and pass the same contract suite; the differences are operational:

| | `PostgresStore` | `SqliteStore` |
|---|-----------------|---------------|
| append serialization | per-tag advisory locks — appends to disjoint tags run in parallel | one writer database-wide (`BEGIN IMMEDIATE`) |
| subscribe wake-up | `LISTEN/NOTIFY`, no polling | polls `PRAGMA data_version` every `poll_interval:` (default 0.1s) |
| `created_at` precision | microseconds | milliseconds |
| tag lookup | GIN index on the `tags` column | `event_tags(tag, sequence_position)` index table |
| in-memory database | n/a | `:memory:` belongs to the connection that opened it — use a file database for anything multi-connection, including `subscribe` |
| shared by several hosts | yes | no: one filesystem |

Rule of thumb: SQLite for single-host deployments, embedded use and test suites that want real SQL; PostgreSQL when appends must proceed in parallel across disjoint consistency boundaries, when several hosts share the store, or when subscribers should wake without polling. `InMemoryStore` (below) covers unit tests that want no database at all.

See `examples/BENCHMARK.md` for the two backends measured side by side, including the cost of decoding a row.

## Usage

### Core concepts

```ruby
require "dcb_event_store"
require "pg"

conn = PG.connect(dbname: "my_event_store")
DcbEventStore::PostgresStore::Schema.create!(conn)
store = DcbEventStore::PostgresStore.new(conn)
```

Or on SQLite, with the same API:

```ruby
require "dcb_event_store"
require "sqlite3"

db = SQLite3::Database.new("events.sqlite3")
DcbEventStore::SqliteStore::Schema.create!(db)
store = DcbEventStore::SqliteStore.new(db)               # poll_interval: 0.1 by default
```

Everything below works the same on either store (and on `InMemoryStore`); the examples use whichever one they were given.

**Events** have a type, data hash, and tags array:

```ruby
event = DcbEventStore::Event.new(
  type: "StudentSubscribedToCourse",
  data: { student_id: "alice", course_id: "math-101" },
  tags: ["student:alice", "course:math-101"]
)
```

**Queries** filter events by type and/or tags:

```ruby
query = DcbEventStore::Query.new([
  DcbEventStore::QueryItem.new(
    event_types: ["StudentSubscribedToCourse"],
    tags: ["course:math-101"]
  )
])

events = store.read(query).to_a
```

**Append conditions** enforce consistency — fail if matching events appeared since your last read:

```ruby
condition = DcbEventStore::AppendCondition.new(
  fail_if_events_match: query,
  after: last_seen_position
)

store.append(event, condition)
# raises DcbEventStore::ConditionNotMet on conflict
```

### Projections and decision models

**Projections** fold events into state:

```ruby
capacity = DcbEventStore::Projection.new(
  initial_state: 0,
  handlers: {
    "CourseDefined" => ->(_state, event) { event.data[:capacity] },
    "CourseCapacityChanged" => ->(_state, event) { event.data[:new_capacity] }
  },
  query: DcbEventStore::Query.new([
    DcbEventStore::QueryItem.new(
      event_types: %w[CourseDefined CourseCapacityChanged],
      tags: ["course:math-101"]
    )
  ])
)
```

**DecisionModel** reads once, folds multiple projections, and returns an append condition:

```ruby
result = DcbEventStore::DecisionModel.build(store,
  capacity: capacity_projection,
  subscriptions: subscription_count_projection
)

result.states[:capacity]       # => 30
result.states[:subscriptions]  # => 12
result.append_condition        # use this when appending
```

### Snapshots

A decision model re-reads and re-folds every matching event on every build, so its cost grows with the length of the projection's history — a "popular course" with 10,000 subscriptions costs ~400ms per decision on either backend, nearly all of it row decoding. Snapshots cap that: a projection's folded state is stored at a sequence position, and the next build reads only the events after it (2–5ms for the same decision; measurements and design notes in `examples/SNAPSHOTS.md`). A projection opts in with a `Snapshot`, and `DecisionModel.build` takes the store to keep them in:

```ruby
snapshots = DcbEventStore::Snapshots::PostgresSnapshotStore.new(conn)   # or SqliteSnapshotStore.new(db)

course_subscriptions = DcbEventStore::Projection.new(
  initial_state: 0,
  handlers: { "StudentSubscribedToCourse" => ->(count, _e) { count + 1 } },
  query: DcbEventStore::Query.new([
    DcbEventStore::QueryItem.new(event_types: ["StudentSubscribedToCourse"], tags: ["course:math-101"])
  ]),
  snapshot: DcbEventStore::Snapshot.new(name: "course_subscriptions", version: 1, every: 1)
)

result = DcbEventStore::DecisionModel.build(store, snapshots: snapshots,
  capacity: capacity_projection,             # no snapshot: always folded from the start
  subscriptions: course_subscriptions        # folded from its snapshot, when one exists
)
```

- The `projection_snapshots` table is part of the schema `Schema.create!` installs on both backends; nothing extra to set up.
- The snapshot **key** is `name`, `version` and the projection's query (`Query#fingerprint`, a JSON rendering of its items that carries the entity's tags — replaced by its SHA-256 when longer than the digest itself, so keys stay under 64 characters plus the prefix), so one `Snapshot` configuration serves every instance of a projection and each entity gets its own snapshot.
- **Invalidation is explicit.** Nothing can detect that a handler or `initial_state` changed, so `version:` is required (no default): bump it whenever the fold would compute differently, and the old snapshots are never read again. A query change needs no bump (the key already differs). For a change that touches every projection at once, set `DcbEventStore::Snapshots.epoch = "<release>"` at boot: it prefixes every key, so one knob invalidates everything.
- **Cleanup:** stale rows are never read but stay in the table until purged: `snapshots.purge(name: "course_subscriptions", keep_version: 2)` drops the other versions of a projection (`keep_version:` omitted drops them all), and `snapshots.purge_other_epochs` drops everything not under the current epoch. Both return the number of rows removed.
- A build with snapshots first takes the store's `last_position` (the log head), then reads; its append condition guards up to that head, and snapshots are written there, so the state a snapshot holds is exactly the state the build returned.
- `every:` is the write policy: a snapshot is written the first time a projection is built and thereafter once the head has moved at least `every` positions past it — whether the events in between matched the projection or not, since the next catch-up read would have to look past them. `every: 1` (one upsert per projection per build that saw any append) keeps the catch-up read shortest and is the right default for decision models.
- `DecisionModel.build` groups projections by snapshot position and issues one read per group (projections without a snapshot read from the start of the log, but only their own query), so a projection over a brand-new entity does not force the others to replay.
- State is stored as JSON by the SQL stores, so JSON-compatible states (numbers, strings, booleans, arrays, symbol-keyed hashes) round-trip as they are; anything else takes `dump:`/`load:` lambdas on the `Snapshot`.
- `Snapshots::InMemorySnapshotStore` keeps the states in the process (a warm cache, lost on restart). It stores the very objects the fold produced, so handlers that mutate their state in place need `dump: Marshal.method(:dump), load: Marshal.method(:load)` or must return new objects.
- Snapshots keep the DCB guarantees only as far as a read does: a snapshot position means "every matching event up to here was visible when it was read", which holds on SQLite and `InMemoryStore` (single writer, positions commit in order) and on PostgreSQL under the same per-tag locking that already protects the append condition.
- On PostgreSQL, keep `autovacuum_analyze_scale_factor` low on the `events` table (e.g. `0.01`): with stale statistics the planner walks the primary key for the catch-up read, and the walk grows with everything appended since the snapshot. `examples/SNAPSHOTS.md` §3.1 has the measurements.

### Client (causation/correlation wiring)

`Client` wraps a store and auto-stamps events with `correlation_id` and `causation_id`:

```ruby
client = DcbEventStore::Client.new(store)
client.correlation_id  # => auto-generated UUID

# Events appended through client get stamped automatically
client.append(event, condition)

# Chain causation across command handlers
next_client = client.caused_by(triggering_event)
```

### Upcasting (schema evolution)

Transform event data on read to handle schema changes:

```ruby
upcaster = DcbEventStore::Upcaster.new
upcaster.register("CourseDefined", from_version: 1) do |data|
  data.merge(status: "active")  # v1 -> v2: add default status
end

store = DcbEventStore::PostgresStore.new(conn, upcaster: upcaster)
```

### Real-time subscriptions

```ruby
store.subscribe(query, after: last_position) do |event|
  # called for each new matching event (blocks the caller)
end
```

Uses PostgreSQL `LISTEN/NOTIFY` with catch-up reads.

On SQLite there is no `LISTEN/NOTIFY`, so the same call polls: it sleeps `poll_interval:` (default 0.1s) and only reads again once the database changed.

```ruby
store = DcbEventStore::SqliteStore.new(db, poll_interval: 0.05)
```

A subscriber should open its **own `SQLite3::Database` on the same file** (the change check is `PRAGMA data_version`, which only moves for other connections' commits; a store appending and subscribing over one connection is detected too, through that connection's own change counter). A `:memory:` database belongs to the connection that opened it and cannot be subscribed to from another one.

### Instrumentation (observability)

The gem ships a lightweight notification framework modeled on `ActiveSupport::Notifications`. Store operations, projection folds and decision model builds emit timed events through a process-wide `DcbEventStore::Notifications` instance; adapters subscribe and forward them to monitoring systems. With no subscribers the emission points are near-zero cost.

```ruby
# Subscribe to everything (nil pattern), one event name (String), or a Regexp
subscription = DcbEventStore.instrumentation.subscribe(/\.dcb\z/) do |event|
  event.name      # "append.dcb"
  event.duration  # seconds, from a monotonic clock
  event.payload   # operation-specific Hash (see below)
  event.error     # the raised exception, or nil
end

DcbEventStore.instrumentation.unsubscribe(subscription)
```

Emitted events and payloads:

| Event | Emitted by | Payload |
|-------|------------|---------|
| `append.dcb` | `SqlStore#append` (both SQL backends), `InMemoryStore#append` | `store:`, `event_count:`, `event_types:`, `condition:` (boolean), plus `appended_count:` and `last_position:` on success |
| `read.dcb` | `SqlStore#read`/`#read_from`, `InMemoryStore#read`/`#read_from` | `store:`, `query:`, `after:`, `event_count:` |
| `projection.dcb` | `Projection#fold` | `event_types:`, `event_count:` |
| `decision_model.dcb` | `DecisionModel.build` | `projections:` (names), `event_count:`, `last_position:`, and with a snapshot store `snapshots_loaded:`, `snapshots_written:` |
| `snapshot.dcb` | `DecisionModel.build` around its snapshot store calls | `store:` (snapshot store), `operation: :load` once per build with `projections:`, `requested:`, `loaded:` — `operation: :write` once per snapshot written with `projection:`, `key:`, `position:`, `folded_count:` |
| `subscribe.dcb` | `SqlStore#subscribe`, `InMemoryStore#subscribe` | per event: `store:`, `query:`, `phase:` (`:catch_up`/`:live`), `sequence_position:`, `lag:` — batched: `store:`, `query:`, `phase:`, `event_count:`, `last_position:`, `max_lag:` |

A failed append condition publishes the `append.dcb` event with `event.error` set to the `ConditionNotMet` exception before it propagates — useful for tracking consistency-boundary conflict rates.

`event_count` on `decision_model.dcb` is the number snapshots exist to hold down: with snapshots working it stays flat as a projection's history grows, and `snapshot.dcb`'s `requested:`/`loaded:` give the hit rate.

Reads are lazy enumerators, so `read.dcb` fires when the enumeration finishes (completing or exiting early via `break`/`#first`), with `event_count` reflecting the events actually yielded. Whether a read is instrumented is decided when the read is issued, and an abandoned external iterator (`#next` without exhausting) publishes nothing.

#### Subscription delivery lag

`subscribe.dcb` measures **delivery lag** — the wall-clock time between an event being stored (`created_at`) and its delivery to the subscriber block. It's the staleness signal for anything built on `subscribe` (projectors, read models, process managers); an alert on growing lag is the classic "consumer is falling behind" indicator. Emission granularity is configured per store:

```ruby
store = DcbEventStore::PostgresStore.new(conn)                                    # :event (default)
store = DcbEventStore::PostgresStore.new(conn, subscribe_instrumentation: :batch) # one event per delivery round
```

- `:event` — one `subscribe.dcb` per delivered event with its `sequence_position:` and `lag:`; `event.duration` is the handler time, so transport lag and slow handlers can be told apart.
- `:batch` — one `subscribe.dcb` per delivery round (the whole catch-up, then one per wake-up) with `event_count:`, `last_position:` and `max_lag:`; `event.duration` spans the read plus all handler calls. Use this for high-throughput subscriptions where per-event emission is too noisy.

`phase:` distinguishes `:catch_up` (replaying history, where large lag is expected and shouldn't pollute live-lag metrics) from `:live` deliveries. A handler that raises publishes the event with `event.error` set before the exception propagates. Whether a delivery round is instrumented is decided per round, so subscribers attached mid-subscription observe subsequent rounds.

**Clock skew caveat**: `created_at` is stamped by the database clock (the PostgreSQL server, or the SQLite process itself), while lag is measured against the consumer host's clock. When these are different machines, lag absorbs any skew between them and can even come out slightly negative. Keep both hosts NTP-synced and treat lag as a trend/magnitude signal rather than a precise measurement. (The alternative — measuring from `NOTIFY` arrival — would miss time spent committed-but-undelivered, which is usually the point of the metric.)

**InMemoryStore caveat**: the in-memory store delivers subscriptions synchronously on the appender's thread, so its `:live` events are published during `append` and its lag values are just in-process dispatch overhead (~0). It emits the same event shape so application tests can assert on `subscribe.dcb`, but the lag numbers are only meaningful for the SQL stores.

`DcbEventStore::LogSubscriber` is a proof-of-concept adapter that logs one line per event, and the reference for richer connectors (AppSignal, Prometheus, ...):

```ruby
DcbEventStore::LogSubscriber.new.attach_to   # logs to $stdout
# I, [...]  INFO -- : append.dcb (1.42ms) store=DcbEventStore::PostgresStore event_count=2 event_types=[CourseDefined] condition=true appended_count=2 last_position=17

DcbEventStore::LogSubscriber.new(logger: Rails.logger, pattern: "append.dcb").attach_to
```

#### Rails query-log style

`DcbEventStore::RailsLogSubscriber` renders events the way an ordinary Rails app renders SQL query metrics — a bold, colored label with the duration in parentheses, logged at `debug` so event-store activity blends into the surrounding query log:

```ruby
# In config/initializers/dcb_event_store.rb
DcbEventStore::RailsLogSubscriber.new.attach_to
#   DCB Append (1.4ms)  store=DcbEventStore::PostgresStore event_count=2 event_types=[CourseDefined] condition=true appended_count=2 last_position=17
#   DCB Read (0.5ms)  store=DcbEventStore::PostgresStore query=... after= event_count=12
```

It reuses the same ANSI color codes `ActiveSupport::LogSubscriber` uses (label in bold; red on error), but **takes no dependency on Rails or ActiveSupport** — it logs to `Rails.logger` when Rails is loaded and falls back to `$stdout` otherwise. Override with `logger:`, `pattern:`, or `colorize:` (the last is handy for non-TTY log destinations):

```ruby
DcbEventStore::RailsLogSubscriber.new(colorize: false, pattern: "append.dcb").attach_to
```

#### Rails setup: nothing to do

In a Rails application the gem's railtie does both halves at boot, so store operations are logged out of the box — no initializer:

1. the engine is swapped for `DcbEventStore::ActiveSupportInstrumentation` (below), so every `*.dcb` event flows through `ActiveSupport::Notifications`, where APM agents (AppSignal, Skylight, Datadog), lograge and your own subscribers already look — correctly nested inside the surrounding request/job span;
2. `RailsLogSubscriber` is attached to `Rails.logger`, rendering them in the query log at `debug` (on in development and test, quiet in production until `RAILS_LOG_LEVEL=debug`), honouring `config.colorize_logging`.

```
  DCB Append (1.4ms)  store=DcbEventStore::SqliteStore event_count=1 event_types=[Deposited] condition=false appended_count=1 last_position=7
  DCB Read (0.4ms)  store=DcbEventStore::SqliteStore query=Query[Deposited,Withdrawn{wallet:w1}] event_count=7
```

Both halves are configurable, from `config/application.rb` or an environment file:

```ruby
config.dcb_event_store.log = false            # attach no log subscriber
config.dcb_event_store.logger = MyLogger.new  # default: Rails.logger
config.dcb_event_store.pattern = "append.dcb" # default: every *.dcb event
config.dcb_event_store.colorize = false       # default: config.colorize_logging

# Keep the gem's own engine — e.g. to assign a custom one yourself
config.dcb_event_store.instrumentation = :standalone
```

After boot the attached adapter and its subscription handle are on the same options object, so the logger can be detached later:

```ruby
options = Rails.application.config.dcb_event_store
DcbEventStore.instrumentation.unsubscribe(options.log_subscription)
```

Outside Rails — or with `:standalone` — the same wiring is two lines:

```ruby
# Route all dcb events through ActiveSupport::Notifications
DcbEventStore.instrumentation = DcbEventStore::ActiveSupportInstrumentation.new

# Render them in the query log via the Rails logger
DcbEventStore::RailsLogSubscriber.new.attach_to
```

`ActiveSupportInstrumentation` is a drop-in replacement for the gem's own engine, verified by a shared engine contract.

With the engine swapped, both subscription styles work and can be mixed freely:

```ruby
# Plain ActiveSupport::Notifications — yields ActiveSupport::Notifications::Event
ActiveSupport::Notifications.subscribe(/\.dcb\z/) do |event|
  StatsD.distribution("dcb.#{event.name.delete_suffix('.dcb')}", event.duration)
end

# DcbEventStore API — yields DcbEventStore::Notifications::Event, so the
# bundled adapters (LogSubscriber, RailsLogSubscriber) keep working unchanged
DcbEventStore.instrumentation.subscribe("append.dcb") { |event| ... }
```

Failures follow the ActiveSupport payload convention for AS::N subscribers (`payload[:exception]` / `payload[:exception_object]`) and remain available as `event.error` through the DcbEventStore API. ActiveSupport is loaded lazily when the engine is constructed; the gem itself takes no dependency on it.

#### AppSignal

`DcbEventStore::AppsignalSubscriber` translates events into [AppSignal custom metrics](https://docs.appsignal.com/metrics/custom.html). Add `gem "appsignal"` to your Gemfile (the gem is loaded lazily; this gem takes no dependency on it) and attach the adapter:

```ruby
DcbEventStore::AppsignalSubscriber.new.attach_to
# customizable: prefix: "dcb", pattern: /\.dcb\z/, appsignal: <receiver>
```

| Metric | Type | Meaning |
|--------|------|---------|
| `dcb.<operation>.duration` | distribution (ms) | every operation (`append`, `read`, `subscribe`, `projection`, `decision_model`) |
| `dcb.<operation>.errors` | counter | operations that raised |
| `dcb.append.events` | counter | events actually written (post-dedup) |
| `dcb.append.conflicts` | counter | `ConditionNotMet` failures — the consistency-boundary conflict rate |
| `dcb.subscribe.delivered` | counter | events delivered to subscribers, tagged `phase=live/catch_up` |
| `dcb.subscribe.lag` | distribution (ms) | live delivery lag — the staleness signal; alert on its p95/p99 |
| `dcb.decision_model.events` | distribution | events read per build — flat when snapshots work, growing when they do not |
| `dcb.snapshot.hits` / `dcb.snapshot.misses` | counter | snapshots found / missing on load (hit rate) |
| `dcb.snapshot.writes` | counter | snapshots written |
| `dcb.snapshot.folded` | distribution | events folded on top of a snapshot before it was rewritten (tune `every:`) |

Metrics are tagged with the emitting store (`store=PostgresStore` / `store=SqliteStore` / `store=InMemoryStore`). The adapter encodes the gem's semantics: delivery lag is recorded **only for the `:live` phase** (catch-up replays history, where large lag is expected and would poison the staleness signal), and comes from `lag:` or `max_lag:` depending on the store's `subscribe_instrumentation:` mode.

Because metrics are recorded after each operation completes, the adapter works against either instrumentation engine. For spans inside request traces, use `ActiveSupportInstrumentation` and wrap application entry points with `Appsignal.instrument`.

`DcbEventStore.instrumentation` is replaceable (e.g. with a fresh instance per test). Subscriber management is thread-safe; publication runs synchronously on the instrumented thread, so keep subscribers fast and non-raising.

### In-memory store for fast tests

`InMemoryStore` is a drop-in replacement for either SQL store that needs no database at all, making application test suites (and especially mutation testing) much faster:

```ruby
store = DcbEventStore::InMemoryStore.new   # accepts upcaster: like the SQL stores
client = DcbEventStore::Client.new(store)
```

It implements the same API and semantics — append conditions, idempotent writes, query filtering, upcasting — verified by the shared contract suite (`test/support/store_contract.rb`) that runs against all three stores, plus a side-by-side equivalence test.

Limitations: it is **single-threaded** (no locking; intended for tests only), reads scan the whole log, and `subscribe` never blocks — it catches up and then delivers matching events synchronously as they are appended. For tests that need real SQL without a server, use `SqliteStore` on a temporary file.

## Tests

```bash
bundle exec rake                                    # all tests
bundle exec mutant run                              # mutation testing (all subjects)
bundle exec mutant run 'DcbEventStore::SqlStore#append' # single method
```

`rake` runs everything: the unit tier and the SQLite tier need no server, the PostgreSQL tier expects `dcb_event_store_test` to exist. The SQLite and unit tiers can be run on their own, without PostgreSQL:

```bash
bundle exec ruby -Itest -e 'Dir["test/{unit,sqlite}/**/test_*.rb"].each { |f| require File.expand_path(f) }'
```

Unit, integration, SQLite and concurrency scenarios (20-thread races, retry-after-conflict, event count integrity under 50-thread load), with the backend-neutral behavior expressed once as shared contracts (`test/support/*_contract.rb`) and run against every backend. Mutation testing via [mutant](https://github.com/mbj/mutant) verifies test effectiveness.

## Examples

All examples from [dcb.events](https://dcb.events/examples) are implemented in `examples/`:

| Example | Pattern |
|---------|---------|
| `course_subscriptions.rb` | Multi-entity constraints via dual-tagged events |
| `unique_username.rb` | Global uniqueness with release and retention |
| `invoice_number.rb` | Gap-free monotonic sequences |
| `dynamic_product_price.rb` | Price validation with grace period |
| `event_sourced_aggregate.rb` | Traditional aggregate on DCB (tag-based locking) |
| `opt_in_token.rb` | Token verification without separate token store |
| `prevent_record_duplication.rb` | Idempotency tokens via tags |
| `performance.rb` | Benchmark: seeding, reads, appends, concurrency |
| `snapshot_benchmark.rb` | Benchmark: decision models with snapshots vs. replay (`examples/SNAPSHOTS.md`) |

Run any example:

```bash
bundle exec ruby examples/course_subscriptions.rb
```

`DCB_BACKEND` picks the store they run on — `postgres` (default), `sqlite` or `memory`:

```bash
DCB_BACKEND=sqlite bundle exec ruby examples/course_subscriptions.rb
DCB_BACKEND=memory bundle exec ruby examples/course_subscriptions.rb
```

Every example produces the same output on all three (`examples/support/backend.rb` is the factory). `performance.rb` runs on the two SQL backends:

```bash
bundle exec ruby examples/performance.rb                             # 100k students, 500 courses
bundle exec ruby examples/performance.rb 1000000 2000                # 1M students, 2k courses
DCB_BACKEND=sqlite bundle exec ruby examples/performance.rb 20000 100
```

See `examples/BENCHMARK.md` for performance findings.

## Upgrading

The PostgreSQL store used to be the only one, and carried the unqualified names. They still resolve, as deprecated aliases:

| Old | New |
|-----|-----|
| `DcbEventStore::Store` | `DcbEventStore::PostgresStore` |
| `DcbEventStore::Schema` | `DcbEventStore::PostgresStore::Schema` |
| `DcbEventStore::PgArrayCodec` | `DcbEventStore::PostgresStore::ArrayCodec` |

Nested constants resolve through the alias too (`Store::LockKeys`), so nothing breaks. Ruby reports each use as a deprecated constant when deprecation warnings are enabled (`ruby -w`, `-W:deprecated`, `Warning[:deprecated] = true`).

## Architecture

- **No ORM** — raw `pg` / `sqlite3` driver, minimal SQL surface
- **One template, two backends** — `SqlStore` holds read/append/subscribe; each backend supplies a handful of hooks and a `Dialect`
- **Serialized condition checks** — advisory locks per tag on PostgreSQL, `BEGIN IMMEDIATE` on SQLite
- **Indexed tags** — GIN index on the `tags` column on PostgreSQL, an `event_tags` index table on SQLite
- **Append-only** — database triggers prevent UPDATE/DELETE
- **Idempotent writes** — `ON CONFLICT (event_id) DO NOTHING`
- **`Data.define`** for immutable value objects (Event, SequencedEvent, Query, etc.)
