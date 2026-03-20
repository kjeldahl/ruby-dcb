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

## Tests

```bash
bundle exec rake
```

77 tests covering unit, integration, and concurrency scenarios (20-thread races, retry-after-conflict, event count integrity under 50-thread load).

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
