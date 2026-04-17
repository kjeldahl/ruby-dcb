#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/dcb_event_store'
require 'pg'

conn = PG.connect(dbname: 'dcb_event_store_test')
conn.exec(%q{SET client_min_messages TO warning})
store = DcbEventStore::Store.new(conn)

# Create the same query as DecisionModel.build
combined_items = []
types_and_tags = [
  ['CourseDefined', ['course:course-0']],
  ['CourseDefined', ['course:course-0']],
  ['CourseCapacityChanged', ['course:course-0']],
  ['StudentSubscribedToCourse', ['course:course-0']],
  ['StudentSubscribedToCourse', ['student:student-0', 'course:course-0']]
]

types_and_tags.each do |type, tags|
  combined_items << DcbEventStore::QueryItem.new(event_types: [type], tags: tags)
end

query = DcbEventStore::Query.new(combined_items)
sql, params = store.send(:build_read_sql, query)
puts format('SQL: %s', sql)
puts format('Params: %s', params.inspect)

# Execute the query directly
result = conn.exec_params(sql, params)
puts format('Results: %d rows', result.ntuples)
result.each { |r| puts format('  %s: %s', r['type'], r['tags']) }

conn&.close