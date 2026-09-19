#!/usr/bin/env ruby
# frozen_string_literal: true

# Row-decode benchmark: what it costs to turn stored rows back into
# SequencedEvents, which is what a projection replay spends its time on once
# the query itself is indexed.
#
# Reports three things:
#   1. Replay throughput -- microseconds per event for a full store.read
#   2. Where those microseconds go -- timestamp, JSON payload, tags, construction
#   3. What the timestamp path costs on each of its three routes
#
# The timestamp comparison is the reason this file exists. created_at is the
# only timestamp the gem parses, once per row, and Time.parse used to dominate
# every decoded row. The routes, cheapest first:
#
#   driver    the backend hands back a value needing no parsing at all --
#             PostgreSQL a Time (the store's TIMESTAMPTZ type map), SQLite an
#             Integer (created_at is epoch microseconds)
#   fast      SqlStore::Timestamp, which reads digits out of fixed positions;
#             the fallback for text from a database written before either
#   Time.parse  the general-purpose parser, what the gem used throughout
#
# Usage:
#   ruby examples/decode_performance.rb                      # postgres, 50k events
#   ruby examples/decode_performance.rb 200000               # custom size
#   DCB_BACKEND=sqlite ruby examples/decode_performance.rb

require_relative "../lib/dcb_event_store"
require_relative "support/backend"
require "securerandom"
require "time"

module DecodePerformance
  RUNS = 5

  def self.measure
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = yield
    [result, Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0]
  end

  # Best of RUNS: the fastest run is the one least disturbed by GC and by
  # whatever else the machine was doing.
  def self.best(runs: RUNS)
    yield
    runs.times.map { _, elapsed = measure { yield }; elapsed }.min
  end

  def self.per_event(seconds, count)
    seconds / count * 1_000_000
  end

  # -- Seeding ---------------------------------------------------------------

  def self.seed!(session, count)
    print "Seeding #{count} events into #{session.name}... "
    _, elapsed = measure do
      case session.name
      when "sqlite" then seed_sqlite!(session.connection, count)
      else seed_postgres!(session.connection, count)
      end
    end
    puts "(#{elapsed.round(2)}s)"
  end

  def self.seed_postgres!(conn, count)
    conn.exec("DROP TRIGGER IF EXISTS enforce_append_only ON events")
    conn.exec("TRUNCATE events RESTART IDENTITY")
    conn.exec("COPY events (event_id, type, data, tags, schema_version) FROM STDIN")
    count.times do |i|
      conn.put_copy_data(
        "#{SecureRandom.uuid}\tStudentSubscribedToCourse\t" \
        "{\"student_id\":\"student-#{i}\",\"course_id\":\"course-#{i % 500}\"}\t" \
        "{student:student-#{i},course:course-#{i % 500}}\t1\n"
      )
    end
    conn.put_copy_end
    conn.get_result
    conn.exec("ANALYZE events")
  end

  def self.seed_sqlite!(db, count)
    insert = db.prepare(
      "INSERT INTO events (event_id, type, data, tags, schema_version) VALUES (?, ?, ?, ?, 1)"
    )
    db.execute("BEGIN IMMEDIATE")
    count.times do |i|
      insert.execute(SecureRandom.uuid, "StudentSubscribedToCourse",
                     %({"student_id":"student-#{i}","course_id":"course-#{i % 500}"}),
                     %(["student:student-#{i}","course:course-#{i % 500}"]))
    end
    db.execute("COMMIT")
    insert.close
    db.execute("ANALYZE")
  end

  # -- Benchmarks ------------------------------------------------------------

  def self.replay(session, count)
    query = DcbEventStore::Query.new([
      DcbEventStore::QueryItem.new(event_types: ["StudentSubscribedToCourse"])
    ])
    elapsed = best { session.store.read(query).count }

    puts
    puts "--- Replay: store.read over the whole stream ---"
    puts "  %-34s %7.3f s   %6.2f us/event" % ["#{count} events", elapsed, per_event(elapsed, count)]
    elapsed
  end

  # One raw row, and the mapper the store would decode it with.
  def self.sample_row(session)
    case session.name
    when "sqlite"
      row = session.connection.execute("SELECT * FROM events LIMIT 1").first
      [row, DcbEventStore::SqliteStore::Dialect.new]
    else
      row = session.connection.exec("SELECT * FROM events LIMIT 1")[0]
      [row, DcbEventStore::PostgresStore::Dialect.new]
    end
  end

  def self.breakdown(session)
    row, dialect = sample_row(session)
    mapper = DcbEventStore::SqlStore::RowMapper.new(dialect, nil)
    n = 100_000
    report = lambda do |label, &block|
      elapsed = best { n.times(&block) }
      puts "  %-34s %6.2f us" % [label, per_event(elapsed, n)]
    end

    puts
    puts "--- Decoding one row (n=#{n} per step) ---"
    report.call("whole row -> SequencedEvent") { mapper.to_sequenced_event(row) }
    report.call("  timestamp") { dialect.decode_timestamp(row["created_at"]) }
    report.call("  JSON payload") { JSON.parse(row["data"], symbolize_names: true) }
    report.call("  tags") { dialect.decode_list(row["tags"]) }
    report.call("  Integer() casts") { Integer(row["sequence_position"]); Integer(row["schema_version"]) }
  end

  def self.timestamp_routes(session)
    row, dialect = sample_row(session)
    stored = row["created_at"]
    as_text = as_text(stored)
    n = 200_000

    routes = {
      "driver (#{stored.class})" => -> { dialect.decode_timestamp(stored) },
      "SqlStore::Timestamp (text)" => -> { DcbEventStore::SqlStore::Timestamp.parse(as_text) },
      "Time.parse (text)" => -> { Time.parse(as_text) }
    }

    puts
    puts "--- created_at, per route (n=#{n}) ---"
    puts "  stored as #{stored.inspect}"
    baseline = nil
    routes.each do |label, route|
      elapsed = best { n.times { route.call } }
      micros = per_event(elapsed, n)
      baseline ||= micros
      puts "  %-34s %6.2f us   %4.1fx vs driver" % [label, micros, micros / baseline]
    end
  end

  # The same instant as the backend stored it, rendered the way a database
  # written before the epoch column (SQLite) or the type map (PostgreSQL)
  # would hold it -- so the three routes are compared on one timestamp.
  def self.as_text(stored)
    case stored
    when Integer then Time.at(stored / 1_000_000, stored % 1_000_000, :usec).utc.iso8601(3)
    when Time then stored.getutc.strftime("%Y-%m-%d %H:%M:%S.%6N+00")
    else stored
    end
  end

  # -- Main ------------------------------------------------------------------

  def self.run
    count = (ARGV[0] || 50_000).to_i

    if Examples::Backend.selected == "memory"
      warn "decode_performance.rb needs a SQL backend: InMemoryStore stores " \
           "SequencedEvents as they are and decodes nothing.\n" \
           "Run it with DCB_BACKEND=postgres (default) or DCB_BACKEND=sqlite."
      return
    end

    Examples::Backend.with_session do |session|
      puts "=" * 70
      puts "DCB Row-Decode Benchmark (#{session.name}, best of #{RUNS})"
      puts "=" * 70
      puts

      seed!(session, count)
      replay(session, count)
      breakdown(session)
      timestamp_routes(session)

      puts
      puts "Done."
    end
  end
end

DecodePerformance.run if __FILE__ == $0
