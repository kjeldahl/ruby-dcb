#!/usr/bin/env ruby
# frozen_string_literal: true

# Correct multi-row CTE: condition check + multi-row INSERT in one statement.
# Compares against current production (check-then-insert).
#
# Usage: ruby experiments/run_cte_correct.rb [num_students] [num_courses] [iterations]

require_relative "../lib/dcb_event_store"
require_relative "instrumented_store"
require "pg"
require "securerandom"
require "json"
require "time"
require "zlib"

module CTECorrectExperiment
  MAX_STUDENT_COURSES = 5

  # Correct multi-row CTE: one condition check, one multi-row INSERT, one statement.
  class MultiRowCTEStore < Experiments::InstrumentedStore
    def append(events, condition = nil)
      events = Array(events)
      timing = {}

      with_transaction do
        timing[:lock_wait] = measure { acquire_locks!(condition) }

        if condition
          timing[:condition_check] = 0.0 # merged into insert
          timing[:insert] = measure do
            @sequenced = cte_insert_with_condition(events, condition)
          end
        else
          timing[:insert] = measure do
            @sequenced = append_without_condition(events)
          end
        end

        timing[:notify] = measure do
          notify_position = @sequenced.last&.sequence_position
          @conn.exec("NOTIFY events_appended, '#{notify_position}'") if notify_position
        end

        @sequenced
      end

      timing[:total] = timing.values.sum
      @timings << timing
      @sequenced
    end

    private

    def cte_insert_with_condition(events, condition)
      cond_sql, cond_params = build_condition_sql(condition.fail_if_events_match, condition.after)

      # Build multi-row VALUES clause
      value_rows = []
      insert_params = []
      events.each_with_index do |event, _i|
        offset = cond_params.size + insert_params.size
        value_rows << "($#{offset + 1}::uuid, $#{offset + 2}::text, $#{offset + 3}::jsonb, " \
                      "$#{offset + 4}::text[], $#{offset + 5}::uuid, $#{offset + 6}::uuid, $#{offset + 7}::integer)"
        insert_params.push(
          event.id, event.type, JSON.generate(event.data),
          "{#{event.tags.join(',')}}",
          event.causation_id, event.correlation_id, 1
        )
      end

      sql = <<~SQL
        WITH cond AS (#{cond_sql})
        INSERT INTO events (event_id, type, data, tags, causation_id, correlation_id, schema_version)
        SELECT v.* FROM (VALUES #{value_rows.join(', ')})
          AS v(event_id, type, data, tags, causation_id, correlation_id, schema_version)
        WHERE NOT EXISTS (SELECT 1 FROM cond WHERE count > 0)
        ON CONFLICT (event_id) DO NOTHING
        RETURNING sequence_position, created_at
      SQL

      result = @conn.exec_params(sql, cond_params + insert_params)

      if result.ntuples.zero? && events.any?
        # Disambiguate: condition failure vs all idempotent skips
        check = @conn.exec_params(cond_sql, cond_params)
        raise DcbEventStore::ConditionNotMet, "conflicting event(s)" if check[0]["count"].to_i.positive?
        return []
      end

      # Match returned rows back to events by position order
      result.map.with_index do |row, i|
        row_to_appended_event(events[i], row)
      end
    end
  end

  # -- Projections (same as course subscriptions) ----------------------------

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

  def self.subscribe_student(store, student_id:, course_id:)
    result = DcbEventStore::DecisionModel.build(store,
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
  end

  # -- Helpers ---------------------------------------------------------------

  def self.measure
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
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

  def self.print_summary(label, timings)
    return if timings.empty?
    keys = timings.first.keys
    puts "  #{label}:"
    keys.each do |key|
      values = timings.map { |t| t[key] }.compact.sort
      next if values.empty?
      puts "    %-20s  p50=%7.3f  p90=%7.3f  p99=%7.3f  stddev=%7.3f ms  (n=%d)" % [
        key, percentile(values, 50) * 1000, percentile(values, 90) * 1000,
        percentile(values, 99) * 1000, stddev(values) * 1000, values.size
      ]
    end
  end

  # -- Run -------------------------------------------------------------------

  def self.run
    num_students = (ARGV[0] || 100_000).to_i
    num_courses  = (ARGV[1] || 500).to_i
    n            = (ARGV[2] || 50).to_i
    base         = num_students + 1000

    conn = PG.connect(dbname: "dcb_event_store_test")
    conn.exec("SET client_min_messages TO warning")
    DcbEventStore::Schema.create!(conn)

    stores = {
      "Current (check-then-insert)" => Experiments::InstrumentedStore,
      "Multi-row CTE (correct)" => MultiRowCTEStore,
    }

    stores.each do |name, store_class|
      puts "=" * 78
      puts name
      puts "=" * 78

      seed!(conn, num_students, num_courses)
      store = store_class.new(conn)

      # Sequential
      puts "--- Sequential (n=#{n}) ---"
      store.clear_timings!
      n.times do
        sid = "seq-#{base + rand(1_000_000)}"
        cid = "course-#{rand(num_courses)}"
        subscribe_student(store, student_id: sid, course_id: cid)
      rescue StandardError
        nil
      end
      print_summary("Sequential", store.timings)
      puts

      # Concurrent
      puts "--- Concurrent (10 threads x 10 ops) ---"
      seed!(conn, num_students, num_courses)
      all_timings = []

      elapsed = measure do
        workers = 10.times.map do |ti|
          Thread.new do
            c = PG.connect(dbname: "dcb_event_store_test")
            c.exec("SET client_min_messages TO warning")
            s = store_class.new(c)
            10.times do |oi|
              sid = "conc-#{base + ti * 10_000 + oi}"
              cid = "course-#{rand(num_courses)}"
              subscribe_student(s, student_id: sid, course_id: cid)
            rescue StandardError
              nil
            end
            Thread.current[:timings] = s.timings
          ensure
            c&.close
          end
        end
        workers.each(&:join)
        workers.each { |w| all_timings.concat(w[:timings] || []) }
      end

      puts "  Total: %.0fms, %d ops, %.0f ops/sec" % [elapsed * 1000, all_timings.size, all_timings.size / elapsed]
      print_summary("Concurrent", all_timings)
      puts
    end

    puts "Done."
  ensure
    conn&.close
  end
end

CTECorrectExperiment.run if __FILE__ == $0
