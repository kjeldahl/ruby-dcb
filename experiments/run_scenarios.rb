#!/usr/bin/env ruby
# frozen_string_literal: true

# Cross-scenario performance comparison.
# Tests baseline vs multi-tag+CTE across four contention patterns:
#   1. Course subscriptions (multi-entity, medium contention)
#   2. Invoice numbers (type-only query, total contention)
#   3. Unique usernames (single tag, low contention)
#   4. Idempotency tokens (unique tags, zero contention)
#
# Usage: ruby experiments/run_scenarios.rb

require_relative "../lib/dcb_event_store"
require_relative "instrumented_store"
require_relative "run_experiments"
require "pg"
require "securerandom"
require "json"
require "time"

module ScenarioRunner
  N_SEQ = 50
  N_THREADS = 10
  N_OPS = 10

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

  # -- Seeding helpers -------------------------------------------------------

  def self.reset!(conn)
    conn.exec("DROP TRIGGER IF EXISTS enforce_append_only ON events")
    conn.exec("TRUNCATE events RESTART IDENTITY")
  end

  def self.restore_trigger!(conn)
    conn.exec(<<~SQL)
      CREATE TRIGGER enforce_append_only
        BEFORE UPDATE OR DELETE ON events
        FOR EACH ROW EXECUTE FUNCTION prevent_event_mutation();
    SQL
    conn.exec("ANALYZE events")
  end

  # =========================================================================
  # Scenario 1: Course subscriptions (reuses existing seeder)
  # =========================================================================
  module CourseScenario
    NUM_STUDENTS = 100_000
    NUM_COURSES = 500
    MAX_STUDENT_COURSES = 5

    def self.seed!(conn)
      ScenarioRunner.reset!(conn)
      subs_per_student = [MAX_STUDENT_COURSES, NUM_COURSES].min
      capacity = (NUM_STUDENTS * subs_per_student / NUM_COURSES.to_f * 1.5).ceil

      conn.exec("COPY events (event_id, type, data, tags, schema_version) FROM STDIN")
      NUM_COURSES.times do |i|
        cid = "course-#{i}"
        conn.put_copy_data("#{SecureRandom.uuid}\tCourseDefined\t{\"course_id\":\"#{cid}\",\"capacity\":#{capacity}}\t{course:#{cid}}\t1\n")
      end
      conn.put_copy_end
      conn.get_result

      conn.exec("COPY events (event_id, type, data, tags, schema_version) FROM STDIN")
      NUM_STUDENTS.times do |si|
        sid = "student-#{si}"
        (0...NUM_COURSES).to_a.sample(subs_per_student).each do |ci|
          cid = "course-#{ci}"
          conn.put_copy_data("#{SecureRandom.uuid}\tStudentSubscribedToCourse\t{\"student_id\":\"#{sid}\",\"course_id\":\"#{cid}\"}\t{student:#{sid},course:#{cid}}\t1\n")
        end
      end
      conn.put_copy_end
      conn.get_result
      ScenarioRunner.restore_trigger!(conn)
    end

    def self.do_append(store, i)
      sid = "new-student-#{NUM_STUDENTS + i}"
      cid = "course-#{rand(NUM_COURSES)}"
      ExperimentRunner.subscribe_student(store, student_id: sid, course_id: cid)
    end
  end

  # =========================================================================
  # Scenario 2: Invoice numbers (total contention)
  # =========================================================================
  module InvoiceScenario
    NUM_INVOICES = 10_000 # small: type-only query reads ALL events

    def self.seed!(conn)
      ScenarioRunner.reset!(conn)
      conn.exec("COPY events (event_id, type, data, tags, schema_version) FROM STDIN")
      NUM_INVOICES.times do |i|
        num = i + 1
        conn.put_copy_data("#{SecureRandom.uuid}\tInvoiceCreated\t{\"invoice_number\":#{num},\"invoice_data\":{}}\t{invoice:#{num}}\t1\n")
      end
      conn.put_copy_end
      conn.get_result
      ScenarioRunner.restore_trigger!(conn)
    end

    def self.next_invoice_number
      DcbEventStore::Projection.new(
        initial_state: 1,
        handlers: { "InvoiceCreated" => ->(_s, e) { e.data[:invoice_number] + 1 } },
        query: DcbEventStore::Query.new([
          DcbEventStore::QueryItem.new(event_types: ["InvoiceCreated"])
        ])
      )
    end

    def self.do_append(store, _i)
      result = DcbEventStore::DecisionModel.build(store,
        next_number: next_invoice_number
      )
      number = result.states[:next_number]
      store.append(
        DcbEventStore::Event.new(
          type: "InvoiceCreated",
          data: { invoice_number: number, invoice_data: {} },
          tags: ["invoice:#{number}"]
        ),
        result.append_condition
      )
    end
  end

  # =========================================================================
  # Scenario 3: Unique usernames (low contention)
  # =========================================================================
  module UsernameScenario
    NUM_USERS = 100_000

    def self.seed!(conn)
      ScenarioRunner.reset!(conn)
      conn.exec("COPY events (event_id, type, data, tags, schema_version) FROM STDIN")
      NUM_USERS.times do |i|
        u = "user-#{i}"
        conn.put_copy_data("#{SecureRandom.uuid}\tAccountRegistered\t{\"username\":\"#{u}\"}\t{username:#{u}}\t1\n")
      end
      conn.put_copy_end
      conn.get_result
      ScenarioRunner.restore_trigger!(conn)
    end

    def self.username_claimed(username)
      DcbEventStore::Projection.new(
        initial_state: false,
        handlers: {
          "AccountRegistered" => ->(_s, _e) { true },
          "AccountClosed" => ->(_s, _e) { false }
        },
        query: DcbEventStore::Query.new([
          DcbEventStore::QueryItem.new(
            event_types: %w[AccountRegistered AccountClosed],
            tags: ["username:#{username}"]
          )
        ])
      )
    end

    def self.do_append(store, i)
      username = "new-user-#{NUM_USERS + i}"
      result = DcbEventStore::DecisionModel.build(store,
        claimed: username_claimed(username)
      )
      raise "claimed" if result.states[:claimed]
      store.append(
        DcbEventStore::Event.new(
          type: "AccountRegistered",
          data: { username: username },
          tags: ["username:#{username}"]
        ),
        result.append_condition
      )
    end
  end

  # =========================================================================
  # Scenario 4: Idempotency tokens (zero contention)
  # =========================================================================
  module IdempotencyScenario
    NUM_ORDERS = 100_000

    def self.seed!(conn)
      ScenarioRunner.reset!(conn)
      conn.exec("COPY events (event_id, type, data, tags, schema_version) FROM STDIN")
      NUM_ORDERS.times do |i|
        oid = "order-#{i}"
        token = SecureRandom.uuid
        conn.put_copy_data("#{SecureRandom.uuid}\tOrderPlaced\t{\"order_id\":\"#{oid}\",\"idempotency_token\":\"#{token}\"}\t{order:#{oid},idempotency:#{token}}\t1\n")
      end
      conn.put_copy_end
      conn.get_result
      ScenarioRunner.restore_trigger!(conn)
    end

    def self.token_used(token)
      DcbEventStore::Projection.new(
        initial_state: false,
        handlers: { "OrderPlaced" => ->(_s, _e) { true } },
        query: DcbEventStore::Query.new([
          DcbEventStore::QueryItem.new(event_types: ["OrderPlaced"], tags: ["idempotency:#{token}"])
        ])
      )
    end

    def self.do_append(store, i)
      oid = "new-order-#{NUM_ORDERS + i}"
      token = SecureRandom.uuid
      result = DcbEventStore::DecisionModel.build(store,
        token_used: token_used(token)
      )
      raise "re-submission" if result.states[:token_used]
      store.append(
        DcbEventStore::Event.new(
          type: "OrderPlaced",
          data: { order_id: oid, idempotency_token: token },
          tags: ["order:#{oid}", "idempotency:#{token}"]
        ),
        result.append_condition
      )
    end
  end

  # =========================================================================
  # Runner
  # =========================================================================

  def self.run_scenario(name, scenario, store_class, conn)
    scenario.seed!(conn)

    # Install stored proc if needed
    ExperimentRunner.create_multi_lock_function!(conn) if store_class == ExperimentRunner::MultiTagCTEStore

    store = store_class.new(conn)

    # Sequential
    store.clear_timings!
    N_SEQ.times do |i|
      scenario.do_append(store, i + rand(1_000_000))
    rescue StandardError
      nil
    end
    seq_timings = store.timings.dup

    # Concurrent
    scenario.seed!(conn)
    ExperimentRunner.create_multi_lock_function!(conn) if store_class == ExperimentRunner::MultiTagCTEStore
    all_timings = []

    elapsed = measure do
      workers = N_THREADS.times.map do |ti|
        Thread.new do
          c = PG.connect(dbname: "dcb_event_store_test")
          c.exec("SET client_min_messages TO warning")
          s = store_class.new(c)
          N_OPS.times do |oi|
            scenario.do_append(s, 900_000 + ti * 10_000 + oi)
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

    conc_ops = all_timings.size
    conc_ops_sec = conc_ops > 0 ? conc_ops / elapsed : 0

    [seq_timings, all_timings, conc_ops_sec]
  end

  def self.run
    conn = PG.connect(dbname: "dcb_event_store_test")
    conn.exec("SET client_min_messages TO warning")
    DcbEventStore::Schema.create!(conn)
    ExperimentRunner.create_multi_lock_function!(conn)

    scenarios = {
      "Course subscriptions (multi-entity)" => CourseScenario,
      "Invoice numbers (total contention)" => InvoiceScenario,
      "Unique usernames (low contention)" => UsernameScenario,
      "Idempotency tokens (zero contention)" => IdempotencyScenario,
    }

    stores = {
      "Baseline" => Experiments::InstrumentedStore,
      "Multi-tag+CTE" => ExperimentRunner::MultiTagCTEStore,
    }

    # Collect results for summary table
    results = {}

    scenarios.each do |scenario_name, scenario|
      puts "=" * 78
      puts scenario_name
      puts "=" * 78
      puts

      stores.each do |store_name, store_class|
        puts "--- #{store_name} ---"
        seq, conc, ops_sec = run_scenario(store_name, scenario, store_class, conn)

        print_summary("Sequential", seq)
        puts "  Concurrent: #{conc.size} ops, %.0f ops/sec" % ops_sec
        print_summary("Concurrent", conc)
        puts

        seq_p50 = seq.any? ? percentile(seq.map { |t| t[:total] }.sort, 50) * 1000 : 0
        conc_p50 = conc.any? ? percentile(conc.map { |t| t[:total] }.sort, 50) * 1000 : 0
        lock_p50 = conc.any? ? percentile(conc.map { |t| t[:lock_wait] }.sort, 50) * 1000 : 0

        results["#{scenario_name} / #{store_name}"] = {
          seq_p50: seq_p50, conc_p50: conc_p50, lock_p50: lock_p50, ops_sec: ops_sec
        }
      end
    end

    # Summary table
    puts "=" * 78
    puts "SUMMARY"
    puts "=" * 78
    puts
    puts "%-50s  %8s  %8s  %8s  %8s" % ["Scenario / Store", "Seq p50", "Conc p50", "Lock p50", "ops/sec"]
    puts "-" * 90
    results.each do |key, r|
      puts "%-50s  %7.2fms  %7.2fms  %7.2fms  %7.0f" % [key, r[:seq_p50], r[:conc_p50], r[:lock_p50], r[:ops_sec]]
    end
    puts
    puts "Done."
  ensure
    conn&.close
  end
end

ScenarioRunner.run if __FILE__ == $0
