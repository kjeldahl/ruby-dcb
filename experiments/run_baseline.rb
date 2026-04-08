#!/usr/bin/env ruby
# frozen_string_literal: true

# Baseline instrumented benchmark.
# Measures where time goes in the append path.
#
# Usage: ruby experiments/run_baseline.rb [num_students] [num_courses]

require_relative "../lib/dcb_event_store"
require_relative "instrumented_store"
require "pg"
require "securerandom"

module BaselineExperiment
  MAX_STUDENT_COURSES = 5

  def self.measure
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
  end

  # -- Projections -----------------------------------------------------------

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
        DcbEventStore::QueryItem.new(event_types: ["StudentSubscribedToCourse"],
                                     tags: ["student:#{student_id}", "course:#{course_id}"])
      ])
    )
  end

  def self.subscribe_student(dm_module, store, student_id:, course_id:)
    result = dm_module.build(store,
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

    store.append(
      DcbEventStore::Event.new(
        type: "StudentSubscribedToCourse",
        data: { student_id: student_id, course_id: course_id },
        tags: ["student:#{student_id}", "course:#{course_id}"]
      ),
      result.append_condition
    )
  end

  # -- Seeding ---------------------------------------------------------------

  def self.seed!(conn, num_students, num_courses)
    subs_per_student = [MAX_STUDENT_COURSES, num_courses].min
    capacity = (num_students * subs_per_student / num_courses.to_f * 1.5).ceil

    puts "Seeding: #{num_courses} courses, #{num_students} students, capacity=#{capacity}/course"

    conn.exec("DROP TRIGGER IF EXISTS enforce_append_only ON events")
    conn.exec("TRUNCATE events RESTART IDENTITY")

    conn.exec("COPY events (event_id, type, data, tags, schema_version) FROM STDIN")
    num_courses.times do |i|
      cid = "course-#{i}"
      conn.put_copy_data("#{SecureRandom.uuid}\tCourseDefined\t{\"course_id\":\"#{cid}\",\"capacity\":#{capacity}}\t{course:#{cid}}\t1\n")
    end
    conn.put_copy_end
    conn.get_result

    conn.exec("COPY events (event_id, type, data, tags, schema_version) FROM STDIN")
    num_students.times do |si|
      sid = "student-#{si}"
      (0...num_courses).to_a.sample(subs_per_student).each do |ci|
        cid = "course-#{ci}"
        conn.put_copy_data("#{SecureRandom.uuid}\tStudentSubscribedToCourse\t{\"student_id\":\"#{sid}\",\"course_id\":\"#{cid}\"}\t{student:#{sid},course:#{cid}}\t1\n")
      end
    end
    conn.put_copy_end
    conn.get_result

    conn.exec(<<~SQL)
      CREATE TRIGGER enforce_append_only
        BEFORE UPDATE OR DELETE ON events
        FOR EACH ROW EXECUTE FUNCTION prevent_event_mutation();
    SQL
    conn.exec("ANALYZE events")

    total = num_courses + (num_students * subs_per_student)
    puts "Seeded #{total} events"
    puts
  end

  # -- Report ----------------------------------------------------------------

  def self.print_summary(label, summary)
    puts "  #{label}:"
    summary.each do |key, stats|
      puts "    %-20s  p50=%7.3f  p90=%7.3f  p99=%7.3f  stddev=%7.3f ms  (n=%d)" % [
        key,
        stats[:p50] * 1000,
        stats[:p90] * 1000,
        stats[:p99] * 1000,
        stats[:stddev] * 1000,
        stats[:n]
      ]
    end
  end

  # -- Run -------------------------------------------------------------------

  def self.run
    num_students = (ARGV[0] || 100_000).to_i
    num_courses  = (ARGV[1] || 500).to_i
    n = (ARGV[2] || 50).to_i

    conn = PG.connect(dbname: "dcb_event_store_test")
    conn.exec("SET client_min_messages TO warning")
    DcbEventStore::Schema.create!(conn)

    seed!(conn, num_students, num_courses)

    store = Experiments::InstrumentedStore.new(conn)
    dm = Experiments::InstrumentedDecisionModel
    base = num_students + 1000

    puts "=" * 78
    puts "BASELINE: Instrumented append breakdown (n=#{n})"
    puts "=" * 78
    puts

    # -- Single-writer append --
    puts "--- Single-writer append (sequential) ---"
    store.clear_timings!
    dm.clear_timings!

    n.times do
      sid = "baseline-#{base + rand(1_000_000)}"
      cid = "course-#{rand(num_courses)}"
      subscribe_student(dm, store, student_id: sid, course_id: cid)
    rescue StandardError
      nil # course full etc
    end

    print_summary("DecisionModel.build", dm.timing_summary)
    print_summary("Store#append phases", store.timing_summary)

    # -- Concurrent (threads) --
    puts
    puts "--- Concurrent: 10 threads x 10 ops ---"

    threads = 10
    ops = 10
    all_store_timings = []
    all_dm_timings = []

    elapsed = measure do
      workers = threads.times.map do |ti|
        Thread.new do
          c = PG.connect(dbname: "dcb_event_store_test")
          c.exec("SET client_min_messages TO warning")
          s = Experiments::InstrumentedStore.new(c)
          d = Experiments::InstrumentedDecisionModel
          ops.times do |oi|
            sid = "conc-#{base + ti * 10_000 + oi}"
            cid = "course-#{rand(num_courses)}"
            subscribe_student(d, s, student_id: sid, course_id: cid)
          rescue StandardError
            nil
          end
          Thread.current[:store_timings] = s.timings
        ensure
          c&.close
        end
      end
      workers.each(&:join)
      workers.each { |w| all_store_timings.concat(w[:store_timings] || []) }
    end

    # Build summary from collected timings
    if all_store_timings.any?
      keys = all_store_timings.first.keys
      summary = keys.each_with_object({}) do |key, h|
        values = all_store_timings.map { |t| t[key] }.compact.sort
        next if values.empty?

        h[key] = {
          p50: percentile(values, 50),
          p90: percentile(values, 90),
          p99: percentile(values, 99),
          stddev: stddev(values),
          n: values.size
        }
      end
      puts "  Total: %.0fms, %d ops, %.0f ops/sec" % [elapsed * 1000, all_store_timings.size, all_store_timings.size / elapsed]
      print_summary("Store#append phases (concurrent)", summary)
    end

    puts
    puts "Done."
  ensure
    conn&.close
  end

  def self.percentile(sorted, p)
    return sorted[0] if sorted.size == 1
    rank = p / 100.0 * (sorted.size - 1)
    low = rank.floor
    high = rank.ceil
    low == high ? sorted[low] : sorted[low] + (rank - low) * (sorted[high] - sorted[low])
  end

  def self.stddev(values)
    avg = values.sum / values.size.to_f
    variance = values.sum { |v| (v - avg)**2 } / values.size
    Math.sqrt(variance)
  end
end

BaselineExperiment.run if __FILE__ == $0
