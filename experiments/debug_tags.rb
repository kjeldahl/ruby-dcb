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

# Use COPY like performance.rb - with proper tag array format
puts 'Testing COPY...'
conn.exec(%q{COPY events (event_id, type, data, tags, schema_version) FROM STDIN})
uuid = SecureRandom.uuid
# Tags must be in PostgreSQL array format {value}
copy_line = %(#{uuid}\tCourseDefined\t{\"id\":\"c0\"}\t{course:c0}\t1\n)
puts format('COPY line: %p', copy_line)
conn.put_copy_data(copy_line)
conn.put_copy_end

result = conn.get_result
puts format('COPY result: %s', result.error_message)

result = conn.exec('SELECT type, data, tags FROM events LIMIT 5')
puts format('Events after COPY: %d', result.ntuples)
result.each do |r|
  puts format('  type=%s, data=%s, tags=%s', r['type'], r['data'], r['tags'].inspect)
end

result = conn.exec(%q{SELECT COUNT(*) FROM events WHERE 'course:c0' = ANY(tags)})
puts format('count with course:c0 tag: %s', result[0]['count'])

conn&.close