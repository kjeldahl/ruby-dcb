#!/usr/bin/env ruby
# frozen_string_literal: true

# Focused run: Baseline vs Exp2 (broken) vs Exp7 (correct multi-lock)
#              vs Exp6 (broken+CTE) vs Exp8 (correct multi-lock+CTE)
#
# Usage: ruby experiments/run_exp7_8.rb [num_students] [num_courses] [iterations]

require_relative "run_experiments"

module Exp78Runner
  def self.run
    num_students = (ARGV[0] || 100_000).to_i
    num_courses  = (ARGV[1] || 500).to_i
    n            = (ARGV[2] || 50).to_i
    base         = num_students + 1000

    conn = PG.connect(dbname: "dcb_event_store_test")
    conn.exec("SET client_min_messages TO warning")
    DcbEventStore::Schema.create!(conn)

    # Install the stored procedure
    ExperimentRunner.create_multi_lock_function!(conn)

    ExperimentRunner.instance_variable_set(:@num_students, num_students)

    experiments = {
      "Baseline (global lock)" => Experiments::InstrumentedStore,
      "Exp 2: Per-tag (BROKEN)" => ExperimentRunner::PerTagLockStore,
      "Exp 7: Multi-tag locks (correct)" => ExperimentRunner::MultiTagLockStore,
      "Exp 6: Per-tag+CTE (BROKEN)" => ExperimentRunner::PerTagCTEStore,
      "Exp 8: Multi-tag+CTE (correct)" => ExperimentRunner::MultiTagCTEStore,
    }

    experiments.each do |name, store_class|
      puts "=" * 78
      puts name
      puts "=" * 78

      ExperimentRunner.seed!(conn, num_students, num_courses)

      # Ensure stored proc exists for each re-seed
      ExperimentRunner.create_multi_lock_function!(conn) if name.include?("Multi")

      store = store_class.new(conn)

      puts "--- Sequential (n=#{n}) ---"
      store.clear_timings!
      n.times do
        sid = "seq-#{base + rand(1_000_000)}"
        cid = "course-#{rand(num_courses)}"
        ExperimentRunner.subscribe_student(store, student_id: sid, course_id: cid)
      rescue StandardError
        nil
      end
      ExperimentRunner.print_summary("Sequential", store.timings)
      puts

      puts "--- Concurrent (10 threads x 10 ops) ---"
      # Install stored proc on each thread's connection for multi-lock experiments
      if name.include?("Multi")
        orig_run_concurrent = method(:run_concurrent_with_setup)
        run_concurrent_with_setup(name, store_class, conn, num_courses, base, num_students)
      else
        ExperimentRunner.run_concurrent("Concurrent", store_class, conn, num_courses, base)
      end
    end

    puts "Done."
  ensure
    conn&.close
  end

  def self.run_concurrent_with_setup(_name, store_class, conn, num_courses, base, num_students)
    threads = 10
    ops = 10
    all_timings = []

    ExperimentRunner.seed!(conn, num_students, num_courses)
    # Function is database-global — created once on main conn, visible to all
    ExperimentRunner.create_multi_lock_function!(conn)

    elapsed = ExperimentRunner.measure do
      workers = threads.times.map do |ti|
        Thread.new do
          c = PG.connect(dbname: "dcb_event_store_test")
          c.exec("SET client_min_messages TO warning")
          s = store_class.new(c)
          ops.times do |oi|
            sid = "exp-#{base + ti * 10_000 + oi}"
            cid = "course-#{rand(num_courses)}"
            ExperimentRunner.subscribe_student(s, student_id: sid, course_id: cid)
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

    succeeded = all_timings.size
    puts "  Total: %.0fms, %d ops, %.0f ops/sec" % [elapsed * 1000, succeeded, succeeded / elapsed]
    ExperimentRunner.print_summary("Concurrent", all_timings)
    puts
  end
end

Exp78Runner.run if __FILE__ == $0
