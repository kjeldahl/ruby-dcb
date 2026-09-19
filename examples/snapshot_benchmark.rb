#!/usr/bin/env ruby
# frozen_string_literal: true

# Measures what projection snapshots and materialized streams buy a decision
# model, against the plain read-everything build.
#
# Seeds the course subscription dataset of performance.rb, adds one course
# per stream size in STREAM_SIZES (a course with exactly that many
# subscriptions), then times the five-projection subscribe_student decision
# model on each course four ways:
#
#   baseline              read + fold the whole stream every time
#   snapshots (db)        Snapshots::<Backend>SnapshotStore in the same database
#   snapshots (memory)    Snapshots::InMemorySnapshotStore
#   materialized streams  MaterializedStreams wrapper around the store
#
# The warm numbers are steady state (the snapshot or stream already exists);
# "snapshot cold" is the first build, which reads everything and also writes
# the snapshots. A final section runs the real write loop (build + append with
# condition) under each strategy, since that is what an application does.
#
# Usage:
#   DCB_BACKEND=sqlite bundle exec ruby examples/snapshot_benchmark.rb            # 20k students, 100 courses
#   bundle exec ruby examples/snapshot_benchmark.rb 100000 500                    # postgres, bigger base
#   ITERATIONS=20 DCB_BACKEND=sqlite bundle exec ruby examples/snapshot_benchmark.rb

require_relative "performance"

module SnapshotBenchmark
  STREAM_SIZES = [10, 100, 1_000, 10_000].freeze
  ITERATIONS = (ENV["ITERATIONS"] || 50).to_i

  Snap = DcbEventStore::Snapshot

  # -- The five subscribe_student projections, snapshot-configurable --------

  def self.item(types, tags)
    DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: types, tags: tags)])
  end

  def self.projections(student_id, course_id, snapshot: nil)
    snap = ->(name) { snapshot && Snap.new(name: name, every: snapshot) }
    {
      course_exists: DcbEventStore::Projection.new(
        initial_state: false, handlers: { "CourseDefined" => ->(_s, _e) { true } },
        query: item(["CourseDefined"], ["course:#{course_id}"]), snapshot: snap["course_exists"]
      ),
      capacity: DcbEventStore::Projection.new(
        initial_state: 0,
        handlers: { "CourseDefined" => ->(_s, e) { e.data[:capacity] },
                    "CourseCapacityChanged" => ->(_s, e) { e.data[:new_capacity] } },
        query: item(%w[CourseDefined CourseCapacityChanged], ["course:#{course_id}"]), snapshot: snap["capacity"]
      ),
      course_subs: DcbEventStore::Projection.new(
        initial_state: 0, handlers: { "StudentSubscribedToCourse" => ->(s, _e) { s + 1 } },
        query: item(["StudentSubscribedToCourse"], ["course:#{course_id}"]), snapshot: snap["course_subs"]
      ),
      student_subs: DcbEventStore::Projection.new(
        initial_state: 0, handlers: { "StudentSubscribedToCourse" => ->(s, _e) { s + 1 } },
        query: item(["StudentSubscribedToCourse"], ["student:#{student_id}"]), snapshot: snap["student_subs"]
      ),
      already: DcbEventStore::Projection.new(
        initial_state: false, handlers: { "StudentSubscribedToCourse" => ->(_s, _e) { true } },
        query: item(["StudentSubscribedToCourse"], ["student:#{student_id}", "course:#{course_id}"]),
        snapshot: snap["already"]
      )
    }
  end

  def self.build(store, student_id, course_id, snapshots: nil, every: nil)
    DcbEventStore::DecisionModel.build(store, snapshots: snapshots, **projections(student_id, course_id, snapshot: every))
  end

  def self.subscribe(store, student_id, course_id, snapshots: nil, every: nil)
    result = build(store, student_id, course_id, snapshots: snapshots, every: every)
    raise "full" if result.states[:course_subs] >= result.states[:capacity]

    store.append(
      DcbEventStore::Event.new(type: "StudentSubscribedToCourse",
                               data: { student_id: student_id, course_id: course_id },
                               tags: ["student:#{student_id}", "course:#{course_id}"]),
      result.append_condition
    )
  end

  # -- Seeding: one course per stream size ------------------------------------

  def self.seed_streams!(store)
    puts "Seeding benchmark courses: #{STREAM_SIZES.map { |n| "bench-#{n} (#{n} subs)" }.join(', ')}"
    STREAM_SIZES.each do |n|
      cid = "bench-#{n}"
      store.append(DcbEventStore::Event.new(type: "CourseDefined", data: { course_id: cid, capacity: n * 10 },
                                            tags: ["course:#{cid}"]))
      (0...n).each_slice(1000) do |slice|
        store.append(slice.map do |i|
          sid = "bs-#{n}-#{i}"
          DcbEventStore::Event.new(type: "StudentSubscribedToCourse", data: { student_id: sid, course_id: cid },
                                   tags: ["student:#{sid}", "course:#{cid}"])
        end)
      end
    end
  end

  def self.snapshot_store(session)
    case session.name
    when "postgres"
      DcbEventStore::Snapshots::PostgresSnapshotStore::Schema.create!(session.connection)
      DcbEventStore::Snapshots::PostgresSnapshotStore.new(session.connection).tap(&:clear)
    when "sqlite"
      DcbEventStore::Snapshots::SqliteSnapshotStore::Schema.create!(session.connection)
      DcbEventStore::Snapshots::SqliteSnapshotStore.new(session.connection).tap(&:clear)
    else
      DcbEventStore::Snapshots::InMemorySnapshotStore.new
    end
  end

  # -- Benchmarks --------------------------------------------------------------

  def self.p50(samples) = Performance.percentile(samples.sort, 50) * 1000

  def self.row(label, samples)
    sorted = samples.sort
    puts "  %-34s p50=%8.2f  p90=%8.2f  p99=%8.2f ms  (n=%d)" % [
      label, Performance.percentile(sorted, 50) * 1000, Performance.percentile(sorted, 90) * 1000,
      Performance.percentile(sorted, 99) * 1000, samples.size
    ]
  end

  def self.times(iterations = ITERATIONS)
    Array.new(iterations) { Performance.measure { yield }.last }
  end

  def self.run_reads(session)
    store = session.store
    db_snaps = snapshot_store(session)
    mem_snaps = DcbEventStore::Snapshots::InMemorySnapshotStore.new
    materialized = DcbEventStore::MaterializedStreams.new(store)
    summary = {}

    STREAM_SIZES.each do |n|
      cid = "bench-#{n}"
      sid = "student-0"
      puts
      puts "--- DecisionModel.build, course with #{n} subscriptions (5 projections) ---"

      base = times { build(store, sid, cid) }
      row("baseline", base)

      db_snaps.clear
      cold = times(5) do
        db_snaps.clear
        build(store, sid, cid, snapshots: db_snaps, every: 1)
      end
      row("snapshot cold (read all + write)", cold)

      build(store, sid, cid, snapshots: db_snaps, every: 1)
      db_warm = times { build(store, sid, cid, snapshots: db_snaps, every: 1) }
      row("snapshots (db), warm", db_warm)

      build(store, sid, cid, snapshots: mem_snaps, every: 1)
      mem_warm = times { build(store, sid, cid, snapshots: mem_snaps, every: 1) }
      row("snapshots (memory), warm", mem_warm)

      build(materialized, sid, cid)
      mat_warm = times { build(materialized, sid, cid) }
      row("materialized streams, warm", mat_warm)

      summary[n] = { baseline: p50(base), cold: p50(cold), db: p50(db_warm), memory: p50(mem_warm), materialized: p50(mat_warm) }
    end

    puts
    puts "| stream | baseline | snapshot cold | snapshots (db) | snapshots (memory) | materialized | speedup db | speedup mem |"
    puts "|---|---|---|---|---|---|---|---|"
    summary.each do |n, s|
      puts "| %d | %.2f | %.2f | %.2f | %.2f | %.2f | %.1fx | %.1fx |" % [
        n, s[:baseline], s[:cold], s[:db], s[:memory], s[:materialized], s[:baseline] / s[:db], s[:baseline] / s[:memory]
      ]
    end
  end

  # The application loop: build a decision model, append one event under its
  # condition, repeat with a fresh student each time so the stream grows.
  def self.run_write_loop(session, n)
    store = session.store
    db_snaps = snapshot_store(session)
    materialized = DcbEventStore::MaterializedStreams.new(store)
    cid = "bench-#{n}"
    iterations = [ITERATIONS, 30].min
    counter = 0
    next_student = -> { "w-#{n}-#{counter += 1}" }

    puts
    puts "--- Write loop on course with #{n} subscriptions: build + append with condition ---"
    row("baseline", times(iterations) { subscribe(store, next_student.call, cid) })

    [1, 10, 100].each do |every|
      db_snaps.clear
      subscribe(store, next_student.call, cid, snapshots: db_snaps, every: every)
      row("snapshots (db), every: #{every}", times(iterations) { subscribe(store, next_student.call, cid, snapshots: db_snaps, every: every) })
    end

    subscribe(materialized, next_student.call, cid)
    row("materialized streams", times(iterations) { subscribe(materialized, next_student.call, cid) })
  end

  def self.run
    num_students = (ARGV[0] || 20_000).to_i
    num_courses = (ARGV[1] || 100).to_i

    Examples::Backend.with_session do |session|
      puts "=" * 70
      puts "DCB Snapshot Benchmark (#{session.name}, #{ITERATIONS} iterations)"
      puts "=" * 70
      if session.name == "memory"
        puts "InMemoryStore: no seeding of the base dataset (whole-log scans), only the benchmark courses"
      else
        Performance.seed!(session, num_students, num_courses)
      end
      seed_streams!(session.store)

      run_reads(session)
      run_write_loop(session, 1_000)
      run_write_loop(session, 10_000)
      puts
      puts "Done."
    end
  end
end

SnapshotBenchmark.run if __FILE__ == $0
