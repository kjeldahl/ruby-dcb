# Step 2: Value Objects

## Goal
Implement the core domain value objects that the rest of the system depends on.

## Files to Create
- `lib/dcb_event_store/event.rb` -- `Event = Data.define(:type, :data, :tags)`
  - `type` coerced to String, `data` defaults to `{}`, `tags` defaults to `[]` and frozen
  - Tags are freeform strings, no format validation
- `lib/dcb_event_store/sequenced_event.rb` -- `SequencedEvent = Data.define(:sequence_position, :type, :data, :tags, :created_at)`
- `lib/dcb_event_store/query.rb`
  - `QueryItem = Data.define(:event_types, :tags)` -- event_types coerced to array of strings, tags coerced to array of strings
  - `Query` class with `attr_reader :items`, constructor takes array of QueryItems
  - `Query.all` class method returns a Query with empty items (match-all sentinel)
  - `Query#match_all?` returns true when items is empty
- `lib/dcb_event_store/append_condition.rb` -- `AppendCondition = Data.define(:fail_if_events_match, :after)`
  - `fail_if_events_match` is a Query, `after` defaults to nil (a SequencePosition integer or nil)

## Update
- `lib/dcb_event_store.rb` -- require all new files

## Done When
- All value objects can be instantiated: `Event.new(type: "Foo", data: {a: 1}, tags: ["x:1"])`
- `Event` instances are frozen/immutable
- `Query.all.match_all?` returns true
- `QueryItem.new(event_types: ["A"], tags: ["t:1"])` works
- `AppendCondition.new(fail_if_events_match: Query.all)` works with nil after
- `require 'dcb_event_store'` loads everything without error
