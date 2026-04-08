#!/usr/bin/env ruby
# frozen_string_literal: true

# Experiment: Tags in a separate table vs TEXT[] array
#
# Compares two schemas:
#   A) Current: events.tags TEXT[] with GIN index, queried via @> operator
#   B) Alternative: event_tags(sequence_position, tag) join table with btree index
#
# Both schemas are seeded with identical data and benchmarked on the same queries.
#
# Usage:
#   ruby experiments/tags_table_benchmark.rb              # 100k students, 500 courses
#   ruby experiments/tags_table_benchmark.rb 200000 1000  # custom

require_relative "../lib/dcb_event_store"
require "pg"
require "securerandom"

module TagsTableBenchmark
  MAX_STUDENT_COURSES = 5

  def self.measure
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = yield
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    [result, elapsed]
  end

  def self.percentile(sorted, p)
    return sorted[0] if sorted.size == 1
    rank = p / 100.0 * (sorted.size - 1)
    low = rank.floor
    high = rank.ceil
    low == high ? sorted[low] : sorted[low] + (rank - low) * (sorted[high] - sorted[low])
  end

  def self.bench(label, iterations: 50)
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
      puts "  %-45s  p50=%7.2f  p90=%7.2f  p99=%7.2f  stddev=%7.2f ms  (n=%d)" % [
        label,
        ms[percentile(sorted, 50)],
        ms[percentile(sorted, 90)],
        ms[percentile(sorted, 99)],
        ms[stddev],
        iterations
      ]
    else
      puts "  %-45s  %7.2f ms" % [label, ms[results.first]]
    end
    sorted
  end

  # ============================================================================
  # Schema A: Current (TEXT[] with GIN)
  # ============================================================================

  def self.setup_array_schema!(conn)
    conn.exec("DROP TABLE IF EXISTS events CASCADE")
    conn.exec(<<~SQL)
      CREATE TABLE events (
        sequence_position BIGSERIAL PRIMARY KEY,
        event_id          UUID NOT NULL DEFAULT gen_random_uuid(),
        type              TEXT NOT NULL,
        data              JSONB NOT NULL DEFAULT '{}',
        tags              TEXT[] NOT NULL DEFAULT '{}',
        causation_id      UUID,
        correlation_id    UUID,
        schema_version    INTEGER NOT NULL DEFAULT 1,
        created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
      );
      CREATE UNIQUE INDEX idx_events_event_id ON events (event_id);
      CREATE INDEX idx_events_type ON events (type);
      CREATE INDEX idx_events_tags ON events USING GIN (tags);
      CREATE INDEX idx_events_correlation_id ON events (correlation_id);
    SQL
  end

  def self.seed_array!(conn, num_students, num_courses)
    subs_per_student = [MAX_STUDENT_COURSES, num_courses].min
    capacity = (num_students * subs_per_student / num_courses.to_f * 1.5).ceil

    conn.exec("TRUNCATE events RESTART IDENTITY")

    # Seed CourseDefined
    conn.exec("COPY events (event_id, type, data, tags, schema_version) FROM STDIN")
    num_courses.times do |i|
      cid = "course-#{i}"
      conn.put_copy_data("#{SecureRandom.uuid}\tCourseDefined\t{\"course_id\":\"#{cid}\",\"capacity\":#{capacity}}\t{course:#{cid}}\t1\n")
    end
    conn.put_copy_end
    conn.get_result

    # Seed StudentSubscribedToCourse
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

    conn.exec("ANALYZE events")
  end

  # ============================================================================
  # Schema B: Separate tags table
  # ============================================================================

  def self.setup_tags_table_schema!(conn)
    conn.exec("DROP TABLE IF EXISTS event_tags CASCADE")
    conn.exec("DROP TABLE IF EXISTS events CASCADE")
    conn.exec(<<~SQL)
      CREATE TABLE events (
        sequence_position BIGSERIAL PRIMARY KEY,
        event_id          UUID NOT NULL DEFAULT gen_random_uuid(),
        type              TEXT NOT NULL,
        data              JSONB NOT NULL DEFAULT '{}',
        causation_id      UUID,
        correlation_id    UUID,
        schema_version    INTEGER NOT NULL DEFAULT 1,
        created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
      );
      CREATE UNIQUE INDEX idx_events_event_id ON events (event_id);
      CREATE INDEX idx_events_type ON events (type);
      CREATE INDEX idx_events_correlation_id ON events (correlation_id);

      CREATE TABLE event_tags (
        sequence_position BIGINT NOT NULL REFERENCES events(sequence_position),
        tag               TEXT NOT NULL
      );
      CREATE INDEX idx_event_tags_tag ON event_tags (tag);
      CREATE INDEX idx_event_tags_tag_pos ON event_tags (tag, sequence_position);
      CREATE INDEX idx_event_tags_pos ON event_tags (sequence_position);
    SQL
  end

  def self.seed_tags_table!(conn, num_students, num_courses)
    subs_per_student = [MAX_STUDENT_COURSES, num_courses].min
    capacity = (num_students * subs_per_student / num_courses.to_f * 1.5).ceil

    conn.exec("TRUNCATE event_tags, events RESTART IDENTITY CASCADE")

    # Seed CourseDefined events
    conn.exec("COPY events (event_id, type, data, schema_version) FROM STDIN")
    num_courses.times do |i|
      cid = "course-#{i}"
      conn.put_copy_data("#{SecureRandom.uuid}\tCourseDefined\t{\"course_id\":\"#{cid}\",\"capacity\":#{capacity}}\t1\n")
    end
    conn.put_copy_end
    conn.get_result

    # Seed tags for CourseDefined (1 tag each: course:X)
    conn.exec("COPY event_tags (sequence_position, tag) FROM STDIN")
    num_courses.times do |i|
      conn.put_copy_data("#{i + 1}\tcourse:course-#{i}\n")
    end
    conn.put_copy_end
    conn.get_result

    # Seed StudentSubscribedToCourse events
    conn.exec("COPY events (event_id, type, data, schema_version) FROM STDIN")
    pos = num_courses + 1
    tag_rows = []
    num_students.times do |si|
      sid = "student-#{si}"
      courses = (0...num_courses).to_a.sample(subs_per_student)
      courses.each do |ci|
        cid = "course-#{ci}"
        conn.put_copy_data("#{SecureRandom.uuid}\tStudentSubscribedToCourse\t{\"student_id\":\"#{sid}\",\"course_id\":\"#{cid}\"}\t1\n")
        tag_rows << [pos, "student:#{sid}", "course:#{cid}"]
        pos += 1
      end
    end
    conn.put_copy_end
    conn.get_result

    # Seed tags for subscriptions (2 tags each: student:X, course:Y)
    conn.exec("COPY event_tags (sequence_position, tag) FROM STDIN")
    tag_rows.each do |seq_pos, *tags|
      tags.each do |tag|
        conn.put_copy_data("#{seq_pos}\t#{tag}\n")
      end
    end
    conn.put_copy_end
    conn.get_result

    conn.exec("ANALYZE events")
    conn.exec("ANALYZE event_tags")
  end

  # ============================================================================
  # Benchmark queries
  # ============================================================================

  # -- Array schema queries --

  def self.read_array_single_course(conn, course_id)
    conn.exec_params(
      "SELECT * FROM events WHERE type = ANY($1::text[]) AND tags @> $2::text[] ORDER BY sequence_position",
      ["{CourseDefined,CourseCapacityChanged,StudentSubscribedToCourse}", "{course:#{course_id}}"]
    ).to_a
  end

  def self.read_array_single_student(conn, student_id)
    conn.exec_params(
      "SELECT * FROM events WHERE type = ANY($1::text[]) AND tags @> $2::text[] ORDER BY sequence_position",
      ["{StudentSubscribedToCourse}", "{student:#{student_id}}"]
    ).to_a
  end

  def self.read_array_intersection(conn, student_id, course_id)
    conn.exec_params(
      "SELECT * FROM events WHERE type = ANY($1::text[]) AND tags @> $2::text[] ORDER BY sequence_position",
      ["{StudentSubscribedToCourse}", "{student:#{student_id},course:#{course_id}}"]
    ).to_a
  end

  def self.read_array_decision_model(conn, student_id, course_id)
    # Simulates the combined query from DecisionModel.build for subscribe_student
    # 5 query items OR'd together
    conn.exec_params(
      <<~SQL, [
        SELECT * FROM events WHERE
          (type = ANY($1::text[]) AND tags @> $2::text[])
          OR (type = ANY($3::text[]) AND tags @> $4::text[])
          OR (type = ANY($5::text[]) AND tags @> $6::text[])
          OR (type = ANY($7::text[]) AND tags @> $8::text[])
          OR (type = ANY($9::text[]) AND tags @> $10::text[])
        ORDER BY sequence_position
      SQL
        "{CourseDefined}", "{course:#{course_id}}",
        "{CourseDefined,CourseCapacityChanged}", "{course:#{course_id}}",
        "{StudentSubscribedToCourse}", "{course:#{course_id}}",
        "{StudentSubscribedToCourse}", "{student:#{student_id}}",
        "{StudentSubscribedToCourse}", "{student:#{student_id},course:#{course_id}}"
      ]
    ).to_a
  end

  def self.count_array_condition(conn, student_id, course_id, after_pos)
    # Condition check: any matching events after position?
    conn.exec_params(
      <<~SQL, [
        SELECT COUNT(*) FROM events WHERE
          ((type = ANY($1::text[]) AND tags @> $2::text[])
           OR (type = ANY($3::text[]) AND tags @> $4::text[])
           OR (type = ANY($5::text[]) AND tags @> $6::text[])
           OR (type = ANY($7::text[]) AND tags @> $8::text[])
           OR (type = ANY($9::text[]) AND tags @> $10::text[]))
          AND sequence_position > $11
      SQL
        "{CourseDefined}", "{course:#{course_id}}",
        "{CourseDefined,CourseCapacityChanged}", "{course:#{course_id}}",
        "{StudentSubscribedToCourse}", "{course:#{course_id}}",
        "{StudentSubscribedToCourse}", "{student:#{student_id}}",
        "{StudentSubscribedToCourse}", "{student:#{student_id},course:#{course_id}}",
        after_pos
      ]
    ).to_a
  end

  # -- Tags table queries --

  def self.read_tags_single_course(conn, course_id)
    conn.exec_params(
      <<~SQL, ["course:#{course_id}", "{CourseDefined,CourseCapacityChanged,StudentSubscribedToCourse}"]
        SELECT e.* FROM events e
        INNER JOIN event_tags et ON et.sequence_position = e.sequence_position
        WHERE et.tag = $1 AND e.type = ANY($2::text[])
        ORDER BY e.sequence_position
      SQL
    ).to_a
  end

  def self.read_tags_single_student(conn, student_id)
    conn.exec_params(
      <<~SQL, ["student:#{student_id}", "{StudentSubscribedToCourse}"]
        SELECT e.* FROM events e
        INNER JOIN event_tags et ON et.sequence_position = e.sequence_position
        WHERE et.tag = $1 AND e.type = ANY($2::text[])
        ORDER BY e.sequence_position
      SQL
    ).to_a
  end

  def self.read_tags_intersection(conn, student_id, course_id)
    # Both tags must be present: use intersection via GROUP BY + HAVING
    conn.exec_params(
      <<~SQL, ["student:#{student_id}", "course:#{course_id}", "{StudentSubscribedToCourse}"]
        SELECT e.* FROM events e
        INNER JOIN event_tags et ON et.sequence_position = e.sequence_position
        WHERE et.tag IN ($1, $2) AND e.type = ANY($3::text[])
        GROUP BY e.sequence_position
        HAVING COUNT(DISTINCT et.tag) = 2
        ORDER BY e.sequence_position
      SQL
    ).to_a
  end

  def self.read_tags_decision_model(conn, student_id, course_id)
    # Equivalent of the 5-projection OR query using the tags table.
    # Items 1-3 only need tag course:X, item 4 needs tag student:Y,
    # item 5 needs both student:Y AND course:X.
    #
    # Strategy: find events matching any of the needed tags, then filter.
    conn.exec_params(
      <<~SQL, [
        WITH matching_positions AS (
          SELECT DISTINCT et.sequence_position
          FROM event_tags et
          WHERE et.tag IN ($1, $2)
        )
        SELECT e.* FROM events e
        INNER JOIN matching_positions mp ON mp.sequence_position = e.sequence_position
        WHERE
          (e.type = ANY($3::text[]) AND EXISTS (SELECT 1 FROM event_tags t WHERE t.sequence_position = e.sequence_position AND t.tag = $1))
          OR (e.type = ANY($4::text[]) AND EXISTS (SELECT 1 FROM event_tags t WHERE t.sequence_position = e.sequence_position AND t.tag = $1))
          OR (e.type = ANY($5::text[]) AND EXISTS (SELECT 1 FROM event_tags t WHERE t.sequence_position = e.sequence_position AND t.tag = $1))
          OR (e.type = ANY($6::text[]) AND EXISTS (SELECT 1 FROM event_tags t WHERE t.sequence_position = e.sequence_position AND t.tag = $2))
          OR (e.type = ANY($7::text[])
              AND EXISTS (SELECT 1 FROM event_tags t WHERE t.sequence_position = e.sequence_position AND t.tag = $1)
              AND EXISTS (SELECT 1 FROM event_tags t WHERE t.sequence_position = e.sequence_position AND t.tag = $2))
        ORDER BY e.sequence_position
      SQL
        "course:#{course_id}",
        "student:#{student_id}",
        "{CourseDefined}",
        "{CourseDefined,CourseCapacityChanged}",
        "{StudentSubscribedToCourse}",
        "{StudentSubscribedToCourse}",
        "{StudentSubscribedToCourse}"
      ]
    ).to_a
  end

  def self.read_tags_decision_model_v2(conn, student_id, course_id)
    # Simpler approach: UNION the separate queries
    conn.exec_params(
      <<~SQL, [
        SELECT DISTINCT e.* FROM (
          SELECT e.sequence_position, e.event_id, e.type, e.data, e.causation_id,
                 e.correlation_id, e.schema_version, e.created_at
          FROM events e
          INNER JOIN event_tags et ON et.sequence_position = e.sequence_position
          WHERE et.tag = $1
            AND e.type = ANY($3::text[])

          UNION

          SELECT e.sequence_position, e.event_id, e.type, e.data, e.causation_id,
                 e.correlation_id, e.schema_version, e.created_at
          FROM events e
          INNER JOIN event_tags et ON et.sequence_position = e.sequence_position
          WHERE et.tag = $2
            AND e.type = ANY($4::text[])
        ) e
        ORDER BY e.sequence_position
      SQL
        "course:#{course_id}",
        "student:#{student_id}",
        "{CourseDefined,CourseCapacityChanged,StudentSubscribedToCourse}",
        "{StudentSubscribedToCourse}"
      ]
    ).to_a
  end

  def self.count_tags_condition(conn, student_id, course_id, after_pos)
    conn.exec_params(
      <<~SQL, [
        SELECT COUNT(*) FROM events e WHERE
          e.sequence_position > $3
          AND EXISTS (
            SELECT 1 FROM event_tags et
            WHERE et.sequence_position = e.sequence_position
            AND et.tag IN ($1, $2)
          )
          AND (
            (e.type = ANY($4::text[]) AND EXISTS (SELECT 1 FROM event_tags t WHERE t.sequence_position = e.sequence_position AND t.tag = $1))
            OR (e.type = ANY($5::text[]) AND EXISTS (SELECT 1 FROM event_tags t WHERE t.sequence_position = e.sequence_position AND t.tag = $2))
            OR (e.type = ANY($6::text[])
                AND EXISTS (SELECT 1 FROM event_tags t WHERE t.sequence_position = e.sequence_position AND t.tag = $1)
                AND EXISTS (SELECT 1 FROM event_tags t WHERE t.sequence_position = e.sequence_position AND t.tag = $2))
          )
      SQL
        "course:#{course_id}",
        "student:#{student_id}",
        after_pos,
        "{CourseDefined,CourseCapacityChanged,StudentSubscribedToCourse}",
        "{StudentSubscribedToCourse}",
        "{StudentSubscribedToCourse}"
      ]
    ).to_a
  end

  # ============================================================================
  # Main
  # ============================================================================

  def self.run
    num_students = (ARGV[0] || 100_000).to_i
    num_courses  = (ARGV[1] || 500).to_i
    n = 50

    conn = PG.connect(dbname: "dcb_event_store_test")
    conn.exec("SET client_min_messages TO warning")

    puts "=" * 80
    puts "Tags Table Experiment"
    puts "  #{num_students} students, #{num_courses} courses, #{n} iterations each"
    puts "=" * 80

    # ==== SCHEMA A: TEXT[] with GIN ====
    puts
    puts "#" * 80
    puts "# SCHEMA A: TEXT[] array with GIN index (current)"
    puts "#" * 80

    print "\nSetting up array schema... "
    _, t = measure { setup_array_schema!(conn) }
    puts "(#{t.round(2)}s)"

    print "Seeding... "
    _, t = measure { seed_array!(conn, num_students, num_courses) }
    puts "(#{t.round(2)}s)"

    # Get max position for condition check benchmark
    max_pos = conn.exec("SELECT MAX(sequence_position) as mp FROM events")[0]["mp"].to_i

    puts
    puts "--- Read queries ---"

    bench("Array: single course tags", iterations: n) do
      read_array_single_course(conn, "course-0")
    end

    bench("Array: single student tags", iterations: n) do
      read_array_single_student(conn, "student-0")
    end

    bench("Array: student+course intersection", iterations: n) do
      read_array_intersection(conn, "student-0", "course-0")
    end

    bench("Array: decision model (5 projections)", iterations: n) do
      read_array_decision_model(conn, "student-0", "course-0")
    end

    bench("Array: decision model random", iterations: n) do
      si = rand(num_students)
      ci = rand(num_courses)
      read_array_decision_model(conn, "student-#{si}", "course-#{ci}")
    end

    puts
    puts "--- Condition check (after max position) ---"

    bench("Array: condition check (no conflict)", iterations: n) do
      read_array_single_course(conn, "course-0")  # warm
      count_array_condition(conn, "student-0", "course-0", max_pos)
    end

    puts
    puts "--- Table stats ---"
    result = conn.exec("SELECT count(*) as cnt, pg_size_pretty(pg_total_relation_size('events')) as size FROM events")
    row = result[0]
    puts "  Events: #{row["cnt"]}, Table size (incl. indexes): #{row["size"]}"

    result = conn.exec(<<~SQL)
      SELECT indexname, pg_size_pretty(pg_relation_size(indexname::regclass)) as size
      FROM pg_indexes WHERE tablename = 'events' ORDER BY indexname
    SQL
    result.each { |r| puts "  Index #{r["indexname"]}: #{r["size"]}" }

    # ==== SCHEMA B: Separate tags table ====
    puts
    puts "#" * 80
    puts "# SCHEMA B: Separate event_tags table with btree indexes"
    puts "#" * 80

    print "\nSetting up tags table schema... "
    _, t = measure { setup_tags_table_schema!(conn) }
    puts "(#{t.round(2)}s)"

    print "Seeding... "
    _, t = measure { seed_tags_table!(conn, num_students, num_courses) }
    puts "(#{t.round(2)}s)"

    max_pos = conn.exec("SELECT MAX(sequence_position) as mp FROM events")[0]["mp"].to_i

    puts
    puts "--- Read queries ---"

    bench("Tags table: single course", iterations: n) do
      read_tags_single_course(conn, "course-0")
    end

    bench("Tags table: single student", iterations: n) do
      read_tags_single_student(conn, "student-0")
    end

    bench("Tags table: student+course intersection", iterations: n) do
      read_tags_intersection(conn, "student-0", "course-0")
    end

    bench("Tags table: decision model (CTE+EXISTS)", iterations: n) do
      read_tags_decision_model(conn, "student-0", "course-0")
    end

    bench("Tags table: decision model (UNION)", iterations: n) do
      read_tags_decision_model_v2(conn, "student-0", "course-0")
    end

    bench("Tags table: decision model random (CTE)", iterations: n) do
      si = rand(num_students)
      ci = rand(num_courses)
      read_tags_decision_model(conn, "student-#{si}", "course-#{ci}")
    end

    bench("Tags table: decision model random (UNION)", iterations: n) do
      si = rand(num_students)
      ci = rand(num_courses)
      read_tags_decision_model_v2(conn, "student-#{si}", "course-#{ci}")
    end

    puts
    puts "--- Condition check (after max position) ---"

    bench("Tags table: condition check (no conflict)", iterations: n) do
      read_tags_single_course(conn, "course-0")  # warm
      count_tags_condition(conn, "student-0", "course-0", max_pos)
    end

    puts
    puts "--- Table stats ---"
    result = conn.exec("SELECT count(*) as cnt, pg_size_pretty(pg_total_relation_size('events')) as size FROM events")
    row = result[0]
    puts "  Events: #{row["cnt"]}, Table size (incl. indexes): #{row["size"]}"

    result = conn.exec("SELECT count(*) as cnt, pg_size_pretty(pg_total_relation_size('event_tags')) as size FROM event_tags")
    row = result[0]
    puts "  Event tags rows: #{row["cnt"]}, Table size (incl. indexes): #{row["size"]}"

    result = conn.exec(<<~SQL)
      SELECT indexname, tablename, pg_size_pretty(pg_relation_size(indexname::regclass)) as size
      FROM pg_indexes WHERE tablename IN ('events', 'event_tags') ORDER BY tablename, indexname
    SQL
    result.each { |r| puts "  Index #{r["indexname"]} (#{r["tablename"]}): #{r["size"]}" }

    combined_size = conn.exec(<<~SQL)[0]["size"]
      SELECT pg_size_pretty(pg_total_relation_size('events') + pg_total_relation_size('event_tags')) as size
    SQL
    puts "  Combined total: #{combined_size}"

    # ==== Correctness check ====
    puts
    puts "--- Correctness check (fixed seed for deterministic data) ---"

    # Use fixed random seed so both schemas get identical data
    srand(42)
    setup_array_schema!(conn)
    seed_array!(conn, num_students, num_courses)
    array_course_count = read_array_single_course(conn, "course-0").size
    array_student_count = read_array_single_student(conn, "student-0").size
    array_intersection = read_array_intersection(conn, "student-0", "course-0").size
    array_dm_count = read_array_decision_model(conn, "student-0", "course-0").size

    srand(42)
    setup_tags_table_schema!(conn)
    seed_tags_table!(conn, num_students, num_courses)
    tags_course_count = read_tags_single_course(conn, "course-0").size
    tags_student_count = read_tags_single_student(conn, "student-0").size
    tags_intersection = read_tags_intersection(conn, "student-0", "course-0").size
    tags_dm_count = read_tags_decision_model(conn, "student-0", "course-0").size
    tags_dm_v2_count = read_tags_decision_model_v2(conn, "student-0", "course-0").size

    puts "  Course-0 events:      array=#{array_course_count}, tags_table=#{tags_course_count}  #{array_course_count == tags_course_count ? 'OK' : 'MISMATCH!'}"
    puts "  Student-0 events:     array=#{array_student_count}, tags_table=#{tags_student_count}  #{array_student_count == tags_student_count ? 'OK' : 'MISMATCH!'}"
    puts "  Intersection events:  array=#{array_intersection}, tags_table=#{tags_intersection}  #{array_intersection == tags_intersection ? 'OK' : 'MISMATCH!'}"
    puts "  Decision model:       array=#{array_dm_count}, tags_cte=#{tags_dm_count}, tags_union=#{tags_dm_v2_count}  #{array_dm_count == tags_dm_count && array_dm_count == tags_dm_v2_count ? 'OK' : 'MISMATCH!'}"

    puts
    puts "Done."
  ensure
    conn&.close
  end
end

TagsTableBenchmark.run if __FILE__ == $0
