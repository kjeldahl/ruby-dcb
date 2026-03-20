#!/usr/bin/env ruby
# frozen_string_literal: true

# Focused run: Baseline vs Exp2 vs Exp3 vs Exp6 (combined)
# Usage: ruby experiments/run_exp6.rb [num_students] [num_courses] [iterations]

require_relative "run_experiments"

module Exp6Runner
  def self.run
    num_students = (ARGV[0] || 100_000).to_i
    num_courses  = (ARGV[1] || 500).to_i
    n            = (ARGV[2] || 50).to_i
    base         = num_students + 1000

    conn = PG.connect(dbname: "dcb_event_store_test")
    conn.exec("SET client_min_messages TO warning")
    DcbEventStore::Schema.create!(conn)

    ExperimentRunner.instance_variable_set(:@num_students, num_students)

    experiments = {
      "Baseline (global lock)" => Experiments::InstrumentedStore,
      "Exp 2: Per-tag locks" => ExperimentRunner::PerTagLockStore,
      "Exp 3: CTE (single stmt)" => ExperimentRunner::CTEStore,
      "Exp 6: Per-tag + CTE" => ExperimentRunner::PerTagCTEStore,
    }

    experiments.each do |name, store_class|
      puts "=" * 78
      puts name
      puts "=" * 78

      ExperimentRunner.seed!(conn, num_students, num_courses)
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
      ExperimentRunner.run_concurrent("Concurrent", store_class, conn, num_courses, base)
    end

    puts "Done."
  ensure
    conn&.close
  end
end

Exp6Runner.run if __FILE__ == $0
