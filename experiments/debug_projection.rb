#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/dcb_event_store'
require 'pg'
require 'securerandom'

conn = PG.connect(dbname: 'dcb_event_store_test')
conn.exec(%q{SET client_min_messages TO warning})
DcbEventStore::Schema.create!(conn)
conn.exec(%q{DROP TRIGGER IF EXISTS enforce_append_only ON events})
conn.exec(%q{TRUNCATE events RESTART IDENTITY})

# Seed using store.append instead of COPY
store = DcbEventStore::Store.new(conn)
10.times do |i|
  store.append(DcbEventStore::Event.new(type: format('E%d', i), data: { i: i }, tags: [format('t:%d', i % 5)]))
end

# Verify events exist
result = conn.exec('SELECT type, count(*) FROM events GROUP BY type ORDER BY type')
puts 'Events in DB:'
result.each { |r| puts format('  %s: %s', r['type'], r['count']) }

proj1 = DcbEventStore::Projection.new(initial_state: 0, handlers: { 'E1' => ->(s, _e) { s + 1 } }, query: DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: ['E1'])]))
proj2 = DcbEventStore::Projection.new(initial_state: 0, handlers: { 'E2' => ->(s, _e) { s + 1 } }, query: DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: ['E2'])]))

result = DcbEventStore::DecisionModel.build(store, p1: proj1, p2: proj2)
puts format('p1=%d, p2=%d, after=%s', result.states[:p1], result.states[:p2], result.append_condition.after.inspect)

conn&.close