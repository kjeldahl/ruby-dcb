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

# Seed 5000 events
conn.exec(%q{COPY events (event_id, type, data, tags, schema_version) FROM STDIN})
5000.times do |i|
  conn.put_copy_data([SecureRandom.uuid, format('Event%d', i % 10), format('{\"id\":%d}', i), format('tag:%d', i % 100), 1].join('\t') + '\n')
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

# Benchmark read
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
100.times do
  store.read(DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: ['Event0'], tags: ['tag:0'])])).count
end
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
puts format('Read 100 times: %.0fms (%.2fms avg per read)', elapsed * 1000, elapsed / 100 * 1000)

conn&.close