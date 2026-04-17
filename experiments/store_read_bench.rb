#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/dcb_event_store'
require 'pg'
require 'securerandom'

num_events = 50000

conn = PG.connect(dbname: 'dcb_event_store_test')
conn.exec(%q{SET client_min_messages TO warning})
DcbEventStore::Schema.create!(conn)

conn.exec(%q{DROP TRIGGER IF EXISTS enforce_append_only ON events})
conn.exec(%q{TRUNCATE events RESTART IDENTITY})

# Seed events
conn.exec(%q{COPY events (event_id, type, data, tags, schema_version) FROM STDIN})
num_events.times do |i|
  conn.put_copy_data([
    SecureRandom.uuid,
    i.even? ? 'CourseDefined' : 'StudentSubscribedToCourse',
    i.even? ? %Q{{\"course_id\":\"c#{i}\",\"capacity\":50}} : %Q{{\"student_id\":\"s#{i}\",\"course_id\":\"c#{i % 100}\"}},
    i.even? ? %Q{course:c#{i}} : %Q{student:s#{i},course:c#{i % 100}},
    '1'
  ].join('\t') + '\n')
end
conn.put_copy_end
conn.get_result

conn.exec(<<~SQL)
  CREATE TRIGGER enforce_append_only
    BEFORE UPDATE OR DELETE ON events
    FOR EACH ROW EXECUTE FUNCTION prevent_event_mutation();
SQL
conn.exec('ANALYZE events')

store = DcbEventStore::Store.new(conn)

puts format('Seeded %d events', num_events)
puts

# Benchmark: raw read time
query = DcbEventStore::Query.new([
  DcbEventStore::QueryItem.new(event_types: ['CourseDefined'], tags: ['course:c0'])
])

n = 20
times = []
n.times do
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  store.read(query).count
  times << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000
end
sorted = times.sort
p50 = sorted[n / 2]
p90 = sorted[(n * 0.9).to_i]
puts format('Store.read (1 event match):  p50=%.2fms  p90=%.2fms', p50, p90)

# Benchmark: read many events
query2 = DcbEventStore::Query.new([
  DcbEventStore::QueryItem.new(event_types: ['StudentSubscribedToCourse'], tags: ['course:c0'])
])

n = 20
times = []
n.times do
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  store.read(query2).count
  times << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000
end
sorted = times.sort
p50 = sorted[n / 2]
p90 = sorted[(n * 0.9).to_i]
event_count = store.read(query2).count
puts format('Store.read (many events):    p50=%.2fms  p90=%.2fms  (found %d events)', p50, p90, event_count)

# Benchmark: combined query (5 items) - same as DecisionModel.build for course-0
combined_query = DcbEventStore::Query.new([
  DcbEventStore::QueryItem.new(event_types: ['CourseDefined'], tags: ['course:c0']),
  DcbEventStore::QueryItem.new(event_types: %w[CourseDefined CourseCapacityChanged], tags: ['course:c0']),
  DcbEventStore::QueryItem.new(event_types: ['StudentSubscribedToCourse'], tags: ['course:c0']),
  DcbEventStore::QueryItem.new(event_types: ['StudentSubscribedToCourse'], tags: ['student:s0']),
  DcbEventStore::QueryItem.new(event_types: ['StudentSubscribedToCourse'], tags: ['student:s0', 'course:c0'])
])

# Also test with real existing tags
combined_query_real = DcbEventStore::Query.new([
  DcbEventStore::QueryItem.new(event_types: ['CourseDefined'], tags: ['course:c0']),
  DcbEventStore::QueryItem.new(event_types: %w[CourseDefined CourseCapacityChanged], tags: ['course:c0']),
  DcbEventStore::QueryItem.new(event_types: ['StudentSubscribedToCourse'], tags: ['course:c0']),
  DcbEventStore::QueryItem.new(event_types: ['StudentSubscribedToCourse'], tags: ['student:s0']),
  DcbEventStore::QueryItem.new(event_types: ['StudentSubscribedToCourse'], tags: ['student:s0', 'course:c0'])
])

n = 20
times = []
n.times do
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  store.read(combined_query).count
  times << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000
end
sorted = times.sort
p50 = sorted[n / 2]
p90 = sorted[(n * 0.9).to_i]
event_count = store.read(combined_query).count
puts format('Store.read (combined 5):     p50=%.2fms  p90=%.2fms  (found %d events)', p50, p90, event_count)

conn&.close