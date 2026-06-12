# dcb_event_store

A Ruby implementation of the [Dynamic Consistency Boundary (DCB)](https://dcb.events) event store pattern, backed by PostgreSQL.

DCB is an alternative to stream-based event stores. Instead of partitioning events into streams with per-stream optimistic concurrency, DCB uses **tags** to define dynamic consistency boundaries and **append conditions** for cross-entity optimistic concurrency checks. A single event can belong to multiple consistency boundaries through its tags.

## Requirements

- Ruby >= 3.3
- PostgreSQL

## Setup

```bash
bundle install
createdb dcb_event_store_test
```

## Usage

### Core concepts

```ruby
require "dcb_event_store"

conn = PG.connect(dbname: "dcb_event_store_test")
DcbEventStore::Schema.create!(conn)
store = DcbEventStore::Store.new(conn)
```

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

store = DcbEventStore::Store.new(conn, upcaster: upcaster)
```

### Real-time subscriptions

```ruby
store.subscribe(query, after: last_position) do |event|
  # called for each new matching event (blocks the caller)
end
```

Uses PostgreSQL `LISTEN/NOTIFY` with catch-up reads.

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
| `append.dcb` | `Store#append`, `InMemoryStore#append` | `store:`, `event_count:`, `event_types:`, `condition:` (boolean), plus `appended_count:` and `last_position:` on success |
| `read.dcb` | `Store#read`/`#read_from`, `InMemoryStore#read`/`#read_from` | `store:`, `query:`, `after:`, `event_count:` |
| `projection.dcb` | `Projection#fold` | `event_types:`, `event_count:` |
| `decision_model.dcb` | `DecisionModel.build` | `projections:` (names), `event_count:`, `last_position:` |
| `subscribe.dcb` | `Store#subscribe`, `InMemoryStore#subscribe` | per event: `store:`, `query:`, `phase:` (`:catch_up`/`:live`), `sequence_position:`, `lag:` — batched: `store:`, `query:`, `phase:`, `event_count:`, `last_position:`, `max_lag:` |

A failed append condition publishes the `append.dcb` event with `event.error` set to the `ConditionNotMet` exception before it propagates — useful for tracking consistency-boundary conflict rates.

Reads are lazy enumerators, so `read.dcb` fires when the enumeration finishes (completing or exiting early via `break`/`#first`), with `event_count` reflecting the events actually yielded. Whether a read is instrumented is decided when the read is issued, and an abandoned external iterator (`#next` without exhausting) publishes nothing.

#### Subscription delivery lag

`subscribe.dcb` measures **delivery lag** — the wall-clock time between an event being stored (`created_at`) and its delivery to the subscriber block. It's the staleness signal for anything built on `subscribe` (projectors, read models, process managers); an alert on growing lag is the classic "consumer is falling behind" indicator. Emission granularity is configured per store:

```ruby
store = DcbEventStore::Store.new(conn)                                    # :event (default)
store = DcbEventStore::Store.new(conn, subscribe_instrumentation: :batch) # one event per delivery round
```

- `:event` — one `subscribe.dcb` per delivered event with its `sequence_position:` and `lag:`; `event.duration` is the handler time, so transport lag and slow handlers can be told apart.
- `:batch` — one `subscribe.dcb` per delivery round (the whole catch-up, then one per `NOTIFY` wake-up) with `event_count:`, `last_position:` and `max_lag:`; `event.duration` spans the read plus all handler calls. Use this for high-throughput subscriptions where per-event emission is too noisy.

`phase:` distinguishes `:catch_up` (replaying history, where large lag is expected and shouldn't pollute live-lag metrics) from `:live` deliveries. A handler that raises publishes the event with `event.error` set before the exception propagates. Whether a delivery round is instrumented is decided per round, so subscribers attached mid-subscription observe subsequent rounds.

**Clock skew caveat**: `created_at` is stamped by the PostgreSQL server clock, while lag is measured against the consumer host's clock. When these are different machines, lag absorbs any skew between them and can even come out slightly negative. Keep both hosts NTP-synced and treat lag as a trend/magnitude signal rather than a precise measurement. (The alternative — measuring from `NOTIFY` arrival — would miss time spent committed-but-undelivered, which is usually the point of the metric.)

**InMemoryStore caveat**: the in-memory store delivers subscriptions synchronously on the appender's thread, so its `:live` events are published during `append` and its lag values are just in-process dispatch overhead (~0). It emits the same event shape so application tests can assert on `subscribe.dcb`, but the lag numbers are only meaningful for the PostgreSQL-backed `Store`.

`DcbEventStore::LogSubscriber` is a proof-of-concept adapter that logs one line per event, and the reference for richer connectors (AppSignal, Prometheus, ...):

```ruby
DcbEventStore::LogSubscriber.new.attach_to   # logs to $stdout
# I, [...]  INFO -- : append.dcb (1.42ms) store=DcbEventStore::Store event_count=2 event_types=[CourseDefined] condition=true appended_count=2 last_position=17

DcbEventStore::LogSubscriber.new(logger: Rails.logger, pattern: "append.dcb").attach_to
```

#### Rails query-log style

`DcbEventStore::RailsLogSubscriber` renders events the way an ordinary Rails app renders SQL query metrics — a bold, colored label with the duration in parentheses, logged at `debug` so event-store activity blends into the surrounding query log:

```ruby
# In config/initializers/dcb_event_store.rb
DcbEventStore::RailsLogSubscriber.new.attach_to
#   DCB Append (1.4ms)  store=DcbEventStore::Store event_count=2 event_types=[CourseDefined] condition=true appended_count=2 last_position=17
#   DCB Read (0.5ms)  store=DcbEventStore::Store query=... after= event_count=12
```

It reuses the same ANSI color codes `ActiveSupport::LogSubscriber` uses (label in bold; red on error), but **takes no dependency on Rails or ActiveSupport** — it logs to `Rails.logger` when Rails is loaded and falls back to `$stdout` otherwise. Override with `logger:`, `pattern:`, or `colorize:` (the last is handy for non-TTY log destinations):

```ruby
DcbEventStore::RailsLogSubscriber.new(colorize: false, pattern: "append.dcb").attach_to
```

#### Rails setup: ActiveSupport::Notifications and the Rails logger

For full Rails integration, swap the instrumentation engine for `DcbEventStore::ActiveSupportInstrumentation` — a drop-in replacement (verified by a shared engine contract) that routes every `*.dcb` event through `ActiveSupport::Notifications`. Anything that consumes AS::N — APM agents (AppSignal, Skylight, Datadog), lograge, your own subscribers — then sees event-store activity natively, correctly nested inside the surrounding request/job spans:

```ruby
# config/initializers/dcb_event_store.rb

# Route all dcb events through ActiveSupport::Notifications
DcbEventStore.instrumentation = DcbEventStore::ActiveSupportInstrumentation.new

# Render them in the query log via the Rails logger
DcbEventStore::RailsLogSubscriber.new.attach_to
```

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

`DcbEventStore.instrumentation` is replaceable (e.g. with a fresh instance per test). Subscriber management is thread-safe; publication runs synchronously on the instrumented thread, so keep subscribers fast and non-raising.

### In-memory store for fast tests

`InMemoryStore` is a drop-in replacement for `Store` with no PostgreSQL dependency, making application test suites (and especially mutation testing) much faster:

```ruby
store = DcbEventStore::InMemoryStore.new   # accepts upcaster: like Store
client = DcbEventStore::Client.new(store)
```

It implements the same API and semantics — append conditions, idempotent writes, query filtering, upcasting — verified by a shared contract suite (`test/support/store_contract.rb`) that runs against both implementations, plus a side-by-side equivalence test.

Limitations: it is **single-threaded** (no locking; intended for tests only), and `subscribe` does not block on `LISTEN/NOTIFY` — it catches up and then delivers matching events synchronously as they are appended.

## Tests

```bash
bundle exec rake                                    # all tests
bundle exec mutant run                              # mutation testing (all subjects)
bundle exec mutant run 'DcbEventStore::Store#append' # single method
```

87 tests covering unit, integration, and concurrency scenarios (20-thread races, retry-after-conflict, event count integrity under 50-thread load). Mutation testing via [mutant](https://github.com/mbj/mutant) verifies test effectiveness.

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

Run any example:

```bash
bundle exec ruby examples/course_subscriptions.rb
```

Run the performance benchmark:

```bash
bundle exec ruby examples/performance.rb              # 100k students, 500 courses
bundle exec ruby examples/performance.rb 1000000 2000  # 1M students, 2k courses
```

See `examples/BENCHMARK.md` for performance findings.

## Architecture

- **No ORM** — raw `pg` gem, minimal SQL surface
- **Advisory lock** (`pg_advisory_xact_lock`) for serialized append condition checks
- **GIN index** on `tags` column for efficient tag-based queries
- **Append-only** — database trigger prevents UPDATE/DELETE
- **Idempotent writes** — `ON CONFLICT (event_id) DO NOTHING`
- **`Data.define`** for immutable value objects (Event, SequencedEvent, Query, etc.)
