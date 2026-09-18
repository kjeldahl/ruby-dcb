#!/usr/bin/env ruby
# frozen_string_literal: true

# Performance benchmark using the course subscription model.
#
# Seeds a large dataset in bulk (PostgreSQL: COPY, SQLite: prepared INSERTs in
# batched IMMEDIATE transactions), then benchmarks DCB operations:
#   - Query selectivity (how well the tag index filters)
#   - DecisionModel.build for subscribe_student (5 projections)
#   - Append with condition check under load
#   - Concurrent appends with contention
#
# Both SQL backends run the same measurements, so their numbers are directly
# comparable; DCB_BACKEND=memory is rejected (see #run).
#
# Usage:
#   ruby examples/performance.rb              # default: 100k students, 500 courses
#   ruby examples/performance.rb 1_000_000 2000  # custom: 1M students, 2k courses
#   DCB_BACKEND=sqlite ruby examples/performance.rb 20000 100

require_relative "../lib/dcb_event_store"
require_relative "support/backend"
require "securerandom"

module Performance
  MAX_STUDENT_COURSES = 5

  def self.measure
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = yield
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    [result, elapsed]
  end

  # -- Projections (same as course_subscriptions example) --------------------

  def self.course_exists(course_id)
    DcbEventStore::Projection.new(
      initial_state: false,
      handlers: { "CourseDefined" => ->(_s, _e) { true } },
      query: DcbEventStore::Query.new([
        DcbEventStore::QueryItem.new(event_types: ["CourseDefined"], tags: ["course:#{course_id}"])
      ])
    )
  end

  def self.course_capacity(course_id)
    DcbEventStore::Projection.new(
      initial_state: 0,
      handlers: {
        "CourseDefined" => ->(_s, e) { e.data[:capacity] },
        "CourseCapacityChanged" => ->(_s, e) { e.data[:new_capacity] }
      },
      query: DcbEventStore::Query.new([
        DcbEventStore::QueryItem.new(event_types: %w[CourseDefined CourseCapacityChanged], tags: ["course:#{course_id}"])
      ])
    )
  end

  def self.course_subscription_count(course_id)
    DcbEventStore::Projection.new(
      initial_state: 0,
      handlers: { "StudentSubscribedToCourse" => ->(s, _e) { s + 1 } },
      query: DcbEventStore::Query.new([
        DcbEventStore::QueryItem.new(event_types: ["StudentSubscribedToCourse"], tags: ["course:#{course_id}"])
      ])
    )
  end

  def self.student_subscription_count(student_id)
    DcbEventStore::Projection.new(
      initial_state: 0,
      handlers: { "StudentSubscribedToCourse" => ->(s, _e) { s + 1 } },
      query: DcbEventStore::Query.new([
        DcbEventStore::QueryItem.new(event_types: ["StudentSubscribedToCourse"], tags: ["student:#{student_id}"])
      ])
    )
  end

  def self.student_already_subscribed(student_id, course_id)
    DcbEventStore::Projection.new(
      initial_state: false,
      handlers: { "StudentSubscribedToCourse" => ->(_s, _e) { true } },
      query: DcbEventStore::Query.new([
        DcbEventStore::QueryItem.new(event_types: ["StudentSubscribedToCourse"], tags: ["student:#{student_id}", "course:#{course_id}"])
      ])
    )
  end

  def self.subscribe_student(client, student_id:, course_id:)
    result = DcbEventStore::DecisionModel.build(client,
      course_exists: course_exists(course_id),
      capacity: course_capacity(course_id),
      course_subscriptions: course_subscription_count(course_id),
      student_subscriptions: student_subscription_count(student_id),
      already_subscribed: student_already_subscribed(student_id, course_id)
    )

    states = result.states
    raise "not exists" unless states[:course_exists]
    raise "already subscribed" if states[:already_subscribed]
    raise "course full" if states[:course_subscriptions] >= states[:capacity]
    raise "student limit" if states[:student_subscriptions] >= MAX_STUDENT_COURSES

    client.append(
      DcbEventStore::Event.new(
        type: "StudentSubscribedToCourse",
        data: { student_id: student_id, course_id: course_id },
        tags: ["student:#{student_id}", "course:#{course_id}"]
      ),
      result.append_condition
    )
  end

  # -- Seeding ---------------------------------------------------------------

  # Same dataset on either backend: `num_courses` CourseDefined events and
  # `num_students * subs_per_student` StudentSubscribedToCourse events, every
  # subscription tagged with both its student and its course.
  def self.seed!(session, num_students, num_courses)
    subs_per_student = [MAX_STUDENT_COURSES, num_courses].min
    capacity = (num_students * subs_per_student / num_courses.to_f * 1.5).ceil

    puts "Seeding: #{num_courses} courses, #{num_students} students, " \
         "#{subs_per_student} subs/student, capacity=#{capacity}/course"
    puts

    total = case session.name
            when "sqlite" then seed_sqlite!(session.connection, num_students, num_courses, subs_per_student, capacity)
            else seed_postgres!(session.connection, num_students, num_courses, subs_per_student, capacity)
            end

    puts
    puts "Total: #{total} events seeded"
    total
  end

  # The COPY protocol, with the append-only trigger dropped for the load and
  # recreated afterwards.
  def self.seed_postgres!(conn, num_students, num_courses, subs_per_student, capacity)
    # Disable triggers and indexes for fast bulk load
    conn.exec("DROP TRIGGER IF EXISTS enforce_append_only ON events")
    conn.exec("TRUNCATE events RESTART IDENTITY")

    total = 0

    # Seed CourseDefined
    print "  Courses... "
    _, t = measure do
      conn.exec("COPY events (event_id, type, data, tags, schema_version) FROM STDIN")
      num_courses.times do |i|
        cid = "course-#{i}"
        conn.put_copy_data("#{SecureRandom.uuid}\tCourseDefined\t{\"course_id\":\"#{cid}\",\"capacity\":#{capacity}}\t{course:#{cid}}\t1\n")
      end
      conn.put_copy_end
      conn.get_result
    end
    total += num_courses
    puts "#{num_courses} events (#{t.round(2)}s)"

    # Seed StudentSubscribedToCourse
    # Each student subscribes to `subs_per_student` random courses
    num_subs = num_students * subs_per_student
    print "  Subscriptions... "
    _, t = measure do
      conn.exec("COPY events (event_id, type, data, tags, schema_version) FROM STDIN")
      num_students.times do |si|
        sid = "student-#{si}"
        courses = (0...num_courses).to_a.sample(subs_per_student)
        courses.each do |ci|
          cid = "course-#{ci}"
          conn.put_copy_data("#{SecureRandom.uuid}\tStudentSubscribedToCourse\t{\"student_id\":\"#{sid}\",\"course_id\":\"#{cid}\"}\t{student:#{sid},course:#{cid}}\t1\n")
        end
      end
      conn.put_copy_end
      conn.get_result
    end
    total += num_subs
    puts "#{num_subs} events (#{t.round(2)}s)"

    # Re-enable trigger
    conn.exec(<<~SQL)
      CREATE TRIGGER enforce_append_only
        BEFORE UPDATE OR DELETE ON events
        FOR EACH ROW EXECUTE FUNCTION prevent_event_mutation();
    SQL

    # Analyze for query planner
    print "  ANALYZE... "
    _, t = measure { conn.exec("ANALYZE events") }
    puts "(#{t.round(2)}s)"

    total
  end

  # SQLite has no COPY: prepared INSERTs, committed every SEED_BATCH events so
  # one IMMEDIATE transaction never grows unbounded. The append-only triggers
  # only fire on UPDATE/DELETE, so the load needs no trigger juggling -- but
  # the rows cannot be deleted either, so the database is dropped and recreated
  # instead of truncated. Every event also writes its event_tags index rows,
  # exactly as SqliteStore#append would.
  SEED_BATCH = 5_000

  def self.seed_sqlite!(db, num_students, num_courses, subs_per_student, capacity)
    DcbEventStore::SqliteStore::Schema.drop!(db)
    DcbEventStore::SqliteStore::Schema.create!(db)

    insert_event = db.prepare(
      "INSERT INTO events (event_id, type, data, tags, schema_version) VALUES (?, ?, ?, ?, 1)"
    )
    insert_tag = db.prepare("INSERT INTO event_tags (tag, sequence_position) VALUES (?, ?)")
    written = 0
    commit_every = lambda do
      written += 1
      return unless (written % SEED_BATCH).zero?

      db.execute("COMMIT")
      db.execute("BEGIN IMMEDIATE")
    end

    total = 0
    db.execute("BEGIN IMMEDIATE")

    print "  Courses... "
    _, t = measure do
      num_courses.times do |i|
        cid = "course-#{i}"
        insert_event.execute(SecureRandom.uuid, "CourseDefined",
                             %({"course_id":"#{cid}","capacity":#{capacity}}), %(["course:#{cid}"]))
        insert_tag.execute("course:#{cid}", db.last_insert_row_id)
        commit_every.call
      end
    end
    total += num_courses
    puts "#{num_courses} events (#{t.round(2)}s)"

    num_subs = num_students * subs_per_student
    print "  Subscriptions... "
    _, t = measure do
      num_students.times do |si|
        sid = "student-#{si}"
        (0...num_courses).to_a.sample(subs_per_student).each do |ci|
          cid = "course-#{ci}"
          insert_event.execute(SecureRandom.uuid, "StudentSubscribedToCourse",
                               %({"student_id":"#{sid}","course_id":"#{cid}"}),
                               %(["student:#{sid}","course:#{cid}"]))
          position = db.last_insert_row_id
          insert_tag.execute("student:#{sid}", position)
          insert_tag.execute("course:#{cid}", position)
          commit_every.call
        end
      end
    end
    total += num_subs
    puts "#{num_subs} events (#{t.round(2)}s)"

    db.execute("COMMIT")
    insert_event.close
    insert_tag.close

    print "  ANALYZE... "
    _, t = measure { db.execute("ANALYZE") }
    puts "(#{t.round(2)}s)"

    total
  end

  # -- Benchmarks ------------------------------------------------------------

  def self.percentile(sorted, p)
    return sorted[0] if sorted.size == 1
    rank = p / 100.0 * (sorted.size - 1)
    low = rank.floor
    high = rank.ceil
    low == high ? sorted[low] : sorted[low] + (rank - low) * (sorted[high] - sorted[low])
  end

  def self.bench(label, iterations: 1)
    results = []
    iterations.times do
      _, t = measure { yield }
      results << t
    end
    sorted = results.sort
    ms = ->(v) { v * 1000 }
    avg = results.sum / results.size
    variance = results.sum { |r| (r - avg)**2 } / results.size
    stddev = Math.sqrt(variance)

    if iterations > 1
      puts "  %-40s  p50=%7.2f  p90=%7.2f  p99=%7.2f  stddev=%7.2f ms  (n=%d)" % [
        label,
        ms[percentile(sorted, 50)],
        ms[percentile(sorted, 90)],
        ms[percentile(sorted, 99)],
        ms[stddev],
        iterations
      ]
    else
      puts "  %-40s  %7.2f ms" % [label, ms[results.first]]
    end
    results
  end

  def self.run_benchmarks(session, num_students, num_courses)
    store = session.store
    client = DcbEventStore::Client.new(store)
    # The tag lookup is a GIN index on PostgreSQL and the event_tags table on
    # SQLite; the labels say which one the numbers belong to.
    tag_index = session.name == "sqlite" ? "event_tags" : "GIN"
    n = 50 # iterations per benchmark
    bench_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    puts
    puts "=" * 78
    puts "BENCHMARKS (#{n} iterations each, all times in ms)"
    puts "=" * 78

    # -- 1. Raw read performance --
    puts
    puts "--- Read: Query selectivity ---"

    bench("read single course (#{tag_index} tags)", iterations: n) do
      q = DcbEventStore::Query.new([
        DcbEventStore::QueryItem.new(event_types: %w[CourseDefined CourseCapacityChanged StudentSubscribedToCourse], tags: ["course:course-0"])
      ])
      store.read(q).count
    end

    bench("read single student (#{tag_index} tags)", iterations: n) do
      q = DcbEventStore::Query.new([
        DcbEventStore::QueryItem.new(event_types: ["StudentSubscribedToCourse"], tags: ["student:student-0"])
      ])
      store.read(q).count
    end

    bench("read student+course intersection", iterations: n) do
      q = DcbEventStore::Query.new([
        DcbEventStore::QueryItem.new(event_types: ["StudentSubscribedToCourse"], tags: ["student:student-0", "course:course-0"])
      ])
      store.read(q).count
    end

    # -- 2. DecisionModel.build (the 5-projection subscribe check) --
    puts
    puts "--- DecisionModel.build: subscribe_student (5 projections) ---"

    bench("popular course (many subs)", iterations: n) do
      DcbEventStore::DecisionModel.build(client,
        course_exists: course_exists("course-0"),
        capacity: course_capacity("course-0"),
        course_subs: course_subscription_count("course-0"),
        student_subs: student_subscription_count("student-0"),
        already: student_already_subscribed("student-0", "course-0")
      )
    end

    bench("random course", iterations: n) do
      ci = rand(num_courses)
      si = rand(num_students)
      DcbEventStore::DecisionModel.build(client,
        course_exists: course_exists("course-#{ci}"),
        capacity: course_capacity("course-#{ci}"),
        course_subs: course_subscription_count("course-#{ci}"),
        student_subs: student_subscription_count("student-#{si}"),
        already: student_already_subscribed("student-#{si}", "course-#{ci}")
      )
    end

    # -- 3. Append with condition check --
    puts
    puts "--- Append: with condition check ---"

    # Use high student IDs to avoid conflicts with seeded data
    base = num_students + 1000

    bench("append + condition (new student)", iterations: n) do |i|
      sid = "student-#{base + rand(1_000_000)}"
      cid = "course-#{rand(num_courses)}"
      begin
        subscribe_student(client, student_id: sid, course_id: cid)
      rescue => e
        # course might be full, that's ok
      end
    end

    # -- 4. Condition-only check (no write) --
    puts
    puts "--- Condition check only (no write) ---"

    bench("condition: already subscribed student", iterations: n) do
      result = DcbEventStore::DecisionModel.build(client,
        course_exists: course_exists("course-0"),
        capacity: course_capacity("course-0"),
        course_subs: course_subscription_count("course-0"),
        student_subs: student_subscription_count("student-0"),
        already: student_already_subscribed("student-0", "course-0")
      )
      # don't append, just check
      result.states[:already_subscribed]
    end

    # -- 5. Concurrent append throughput --
    puts
    puts "--- Concurrent: 10 threads appending to different courses ---"

    threads = 10
    ops_per_thread = 5
    total_ops = threads * ops_per_thread
    failures = 0

    _, elapsed = measure do
      workers = threads.times.map do |ti|
        Thread.new do
          s, closer = session.connect
          cl = DcbEventStore::Client.new(s)
          ops_per_thread.times do |oi|
            sid = "perf-#{base + ti * 1000 + oi}"
            cid = "course-#{rand(num_courses)}"
            begin
              subscribe_student(cl, student_id: sid, course_id: cid)
            rescue
              Thread.current[:failures] = (Thread.current[:failures] || 0) + 1
            end
          end
        ensure
          closer&.call
        end
      end
      workers.each(&:join)
      failures = workers.sum { |w| w[:failures] || 0 }
    end

    succeeded = total_ops - failures
    puts "  %-40s  %7.2f ms total, %d/%d succeeded, %.0f ops/sec" % [
      "#{threads} threads x #{ops_per_thread} ops",
      elapsed * 1000,
      succeeded, total_ops,
      succeeded / elapsed
    ]

    # -- 6. Concurrent append throughput (processes) --
    puts
    # Each worker opens its own connection; the parent's handle is inherited
    # and closed unused in the child, which the sqlite3 gem warns about on
    # every fork.
    SQLite3::ForkSafety.suppress_warnings! if defined?(SQLite3::ForkSafety)
    num_procs = 10
    puts "--- Concurrent: #{num_procs} processes, scaling ops/proc ---"

    [5, 20, 50, 100].each do |ops_per_proc|
      total_proc_ops = num_procs * ops_per_proc
      pipes = num_procs.times.map { IO.pipe }

      _, proc_elapsed = measure do
        pids = num_procs.times.map do |pi|
          fork do
            pipes.each_with_index do |(r, _w), i|
              r.close if i != pi
            end
            _, w = pipes[pi]
            s, closer = session.connect
            cl = DcbEventStore::Client.new(s)
            ok = 0
            fail_count = 0
            ops_per_proc.times do |oi|
              sid = "proc-#{base + pi * 100_000 + oi}"
              cid = "course-#{rand(num_courses)}"
              begin
                subscribe_student(cl, student_id: sid, course_id: cid)
                ok += 1
              rescue
                fail_count += 1
              end
            end
            w.write("#{ok},#{fail_count}")
            w.close
            closer&.call
          ensure
            exit!(0)
          end
        end

        pipes.each { |_r, w| w.close }
        proc_results = pipes.map { |r, _w| r.read.tap { r.close } }
        pids.each { |pid| Process.waitpid(pid) }

        @proc_succeeded = 0
        proc_results.each do |res|
          ok, _fl = res.split(",").map(&:to_i)
          @proc_succeeded += ok
        end
      end

      puts "  %-40s  %7.0f ms total, %d/%d succeeded, %5.0f ops/sec" % [
        "#{num_procs} procs x #{ops_per_proc} ops",
        proc_elapsed * 1000,
        @proc_succeeded, total_proc_ops,
        @proc_succeeded / proc_elapsed
      ]
    end

    bench_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - bench_start
    puts
    puts "Benchmarks completed in %.2fs" % bench_elapsed

    # -- 7. Table stats --
    puts
    puts "--- Table stats ---"
    session.name == "sqlite" ? sqlite_stats(session.connection) : postgres_stats(session.connection)
  end

  def self.postgres_stats(conn)
    result = conn.exec("SELECT count(*) as cnt, pg_size_pretty(pg_total_relation_size('events')) as size FROM events")
    row = result[0]
    puts "  Events: #{row["cnt"]}, Table size (incl. indexes): #{row["size"]}"

    result = conn.exec(<<~SQL)
      SELECT indexname, pg_size_pretty(pg_relation_size(indexname::regclass)) as size
      FROM pg_indexes WHERE tablename = 'events' ORDER BY indexname
    SQL
    result.each do |r|
      puts "  Index #{r["indexname"]}: #{r["size"]}"
    end
  end

  # SQLite reports no per-table sizes, so this is the whole database file: the
  # events table, the event_tags index table and the indexes on both.
  def self.sqlite_stats(db)
    events = db.get_first_value("SELECT count(*) FROM events")
    tags = db.get_first_value("SELECT count(*) FROM event_tags")
    bytes = db.get_first_value("PRAGMA page_count").to_i * db.get_first_value("PRAGMA page_size").to_i
    puts "  Events: #{events}, event_tags rows: #{tags}"
    puts "  Database size (incl. indexes): #{(bytes / 1024.0 / 1024).round(1)} MB"
  end

  # -- Main ------------------------------------------------------------------

  def self.run
    num_students = (ARGV[0] || 100_000).to_i
    num_courses  = (ARGV[1] || 500).to_i

    if Examples::Backend.selected == "memory"
      warn "performance.rb needs a SQL backend: InMemoryStore scans the whole log per read " \
           "and cannot be shared across threads or processes.\n" \
           "Run it with DCB_BACKEND=postgres (default) or DCB_BACKEND=sqlite."
      return
    end

    Examples::Backend.with_session do |session|
      puts "=" * 70
      puts "DCB Performance Benchmark (#{session.name})"
      puts "=" * 70
      puts

      seed!(session, num_students, num_courses)
      run_benchmarks(session, num_students, num_courses)

      puts
      puts "Done."
    end
  end
end

Performance.run if __FILE__ == $0
