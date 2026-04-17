#!/usr/bin/env ruby
# frozen_string_literal: true

# Quick benchmark for DecisionModel.build performance
require_relative '../lib/dcb_event_store'
require 'pg'
require 'securerandom'

num_students = 5000
num_courses = 50

conn = PG.connect(dbname: 'dcb_event_store_test')
conn.exec(%q{SET client_min_messages TO warning})
DcbEventStore::Schema.create!(conn)

# Clear and seed
conn.exec(%q{DROP TRIGGER IF EXISTS enforce_append_only ON events})
conn.exec(%q{TRUNCATE events RESTART IDENTITY})

capacity = (num_students * 5 / num_courses.to_f * 1.5).ceil

conn.exec(%q{COPY events (event_id, type, data, tags, schema_version) FROM STDIN})
num_courses.times do |i|
  cid = format('course-%d', i)
  conn.put_copy_data([
    SecureRandom.uuid,
    'CourseDefined',
    %Q{{\"course_id\":\"#{cid}\",\"capacity\":#{capacity}}},
    %Q{course:#{cid}},
    '1'
  ].join('\t') + '\n')
end
conn.put_copy_end
conn.get_result

conn.exec(%q{COPY events (event_id, type, data, tags, schema_version) FROM STDIN})
num_students.times do |si|
  sid = format('student-%d', si)
  (0...num_courses).to_a.sample(5).each do |ci|
    cid = format('course-%d', ci)
    conn.put_copy_data([
      SecureRandom.uuid,
      'StudentSubscribedToCourse',
      %Q{{\"student_id\":\"#{sid}\",\"course_id\":\"#{cid}\"}},
      %Q{student:#{sid},course:#{cid}},
      '1'
    ].join('\t') + '\n')
  end
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
client = DcbEventStore::Client.new(store)

# Projections
def course_exists(course_id)
  DcbEventStore::Projection.new(
    initial_state: false,
    handlers: { 'CourseDefined' => ->(_s, _e) { true } },
    query: DcbEventStore::Query.new([
      DcbEventStore::QueryItem.new(event_types: ['CourseDefined'], tags: [format('course:%s', course_id)])
    ])
  )
end

def course_capacity(course_id)
  DcbEventStore::Projection.new(
    initial_state: 0,
    handlers: {
      'CourseDefined' => ->(_s, e) { e.data[:capacity] },
      'CourseCapacityChanged' => ->(_s, e) { e.data[:new_capacity] }
    },
    query: DcbEventStore::Query.new([
      DcbEventStore::QueryItem.new(event_types: %w[CourseDefined CourseCapacityChanged], tags: [format('course:%s', course_id)])
    ])
  )
end

def course_subscription_count(course_id)
  DcbEventStore::Projection.new(
    initial_state: 0,
    handlers: { 'StudentSubscribedToCourse' => ->(s, _e) { s + 1 } },
    query: DcbEventStore::Query.new([
      DcbEventStore::QueryItem.new(event_types: ['StudentSubscribedToCourse'], tags: [format('course:%s', course_id)])
    ])
  )
end

def student_subscription_count(student_id)
  DcbEventStore::Projection.new(
    initial_state: 0,
    handlers: { 'StudentSubscribedToCourse' => ->(s, _e) { s + 1 } },
    query: DcbEventStore::Query.new([
      DcbEventStore::QueryItem.new(event_types: ['StudentSubscribedToCourse'], tags: [format('student:%s', student_id)])
    ])
  )
end

def student_already_subscribed(student_id, course_id)
  DcbEventStore::Projection.new(
    initial_state: false,
    handlers: { 'StudentSubscribedToCourse' => ->(_s, _e) { true } },
    query: DcbEventStore::Query.new([
      DcbEventStore::QueryItem.new(event_types: ['StudentSubscribedToCourse'], tags: [format('student:%s', student_id), format('course:%s', course_id)])
    ])
  )
end

# Run benchmark
n = 10
times = []
n.times do
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  DcbEventStore::DecisionModel.build(client,
    course_exists: course_exists('course-0'),
    capacity: course_capacity('course-0'),
    course_subs: course_subscription_count('course-0'),
    student_subs: student_subscription_count('student-0'),
    already: student_already_subscribed('student-0', 'course-0')
  )
  times << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000
end

median = times.sort[n / 2]
puts format('METRIC decision_model_ms=%.2f', median)

conn&.close