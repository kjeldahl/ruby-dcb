#!/usr/bin/env ruby
# frozen_string_literal: true

# Experiment 10: Fully normalized tags table vs TEXT[] array
#
# Compares three schemas:
#   A) Current: events.tags TEXT[] with GIN index, queried via @> operator
#   B) Exp 9 style: event_tags(sequence_position, tag) denormalized join table
#   C) NEW: Fully normalized: tags(id, value) + event_tags(sequence_position, tag_id) join table
#
# Schema C stores each unique tag value exactly once. The join table uses integer
# foreign keys instead of repeated TEXT values, saving storage and potentially
# improving join performance through smaller indexes.
#
# Usage:
#   ruby experiments/normalized_tags_benchmark.rb              # 100k students, 500 courses
#   ruby experiments/normalized_tags_benchmark.rb 200000 1000  # custom

require_relative "../lib/dcb_event_store"
require "pg"
require "securerandom"

module NormalizedTagsBenchmark
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
    conn.exec("DROP TABLE IF EXISTS event_tags CASCADE")
    conn.exec("DROP TABLE IF EXISTS tags CASCADE")
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
  # Schema B: Denormalized tags table (Exp 9 style)
  # ============================================================================

  def self.setup_denorm_tags_schema!(conn)
    conn.exec("DROP TABLE IF EXISTS event_tags CASCADE")
    conn.exec("DROP TABLE IF EXISTS tags CASCADE")
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

  def self.seed_denorm_tags!(conn, num_students, num_courses)
    subs_per_student = [MAX_STUDENT_COURSES, num_courses].min
    capacity = (num_students * subs_per_student / num_courses.to_f * 1.5).ceil

    conn.exec("TRUNCATE event_tags, events RESTART IDENTITY CASCADE")

    # Events
    conn.exec("COPY events (event_id, type, data, schema_version) FROM STDIN")
    num_courses.times do |i|
      cid = "course-#{i}"
      conn.put_copy_data("#{SecureRandom.uuid}\tCourseDefined\t{\"course_id\":\"#{cid}\",\"capacity\":#{capacity}}\t1\n")
    end
    conn.put_copy_end
    conn.get_result

    # Tags for courses
    conn.exec("COPY event_tags (sequence_position, tag) FROM STDIN")
    num_courses.times do |i|
      conn.put_copy_data("#{i + 1}\tcourse:course-#{i}\n")
    end
    conn.put_copy_end
    conn.get_result

    # Subscriptions
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

    conn.exec("COPY event_tags (sequence_position, tag) FROM STDIN")
    tag_rows.each do |seq_pos, *event_tags|
      event_tags.each do |tag|
        conn.put_copy_data("#{seq_pos}\t#{tag}\n")
      end
    end
    conn.put_copy_end
    conn.get_result

    conn.exec("ANALYZE events")
    conn.exec("ANALYZE event_tags")
  end

  # ============================================================================
  # Schema C: Fully normalized tags (lookup table + join table)
  # ============================================================================

  def self.setup_normalized_tags_schema!(conn)
    conn.exec("DROP TABLE IF EXISTS event_tags CASCADE")
    conn.exec("DROP TABLE IF EXISTS tags CASCADE")
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

      CREATE TABLE tags (
        id    BIGSERIAL PRIMARY KEY,
        value TEXT NOT NULL UNIQUE
      );
      CREATE INDEX idx_tags_value ON tags (value);

      CREATE TABLE event_tags (
        sequence_position BIGINT NOT NULL REFERENCES events(sequence_position),
        tag_id            BIGINT NOT NULL REFERENCES tags(id)
      );
      CREATE INDEX idx_event_tags_tag_id ON event_tags (tag_id);
      CREATE INDEX idx_event_tags_tag_id_pos ON event_tags (tag_id, sequence_position);
      CREATE INDEX idx_event_tags_pos ON event_tags (sequence_position);
    SQL
  end

  def self.seed_normalized_tags!(conn, num_students, num_courses)
    subs_per_student = [MAX_STUDENT_COURSES, num_courses].min
    capacity = (num_students * subs_per_student / num_courses.to_f * 1.5).ceil

    conn.exec("TRUNCATE event_tags, tags, events RESTART IDENTITY CASCADE")

    # First, build all unique tags and insert them
    print "    tags lookup... "
    tag_to_id = {}
    all_tags = []

    num_courses.times { |i| all_tags << "course:course-#{i}" }
    num_students.times { |si| all_tags << "student:student-#{si}" }
    all_tags.uniq!

    conn.exec("COPY tags (value) FROM STDIN")
    all_tags.each { |tag| conn.put_copy_data("#{tag}\n") }
    conn.put_copy_end
    conn.get_result

    # Load tag IDs
    conn.exec("SELECT id, value FROM tags").each do |row|
      tag_to_id[row["value"]] = row["id"].to_i
    end
    puts "#{tag_to_id.size} unique tags"

    # Events: CourseDefined
    conn.exec("COPY events (event_id, type, data, schema_version) FROM STDIN")
    num_courses.times do |i|
      cid = "course-#{i}"
      conn.put_copy_data("#{SecureRandom.uuid}\tCourseDefined\t{\"course_id\":\"#{cid}\",\"capacity\":#{capacity}}\t1\n")
    end
    conn.put_copy_end
    conn.get_result

    # Event tags for courses (via join table with integer IDs)
    conn.exec("COPY event_tags (sequence_position, tag_id) FROM STDIN")
    num_courses.times do |i|
      tag_id = tag_to_id["course:course-#{i}"]
      conn.put_copy_data("#{i + 1}\t#{tag_id}\n")
    end
    conn.put_copy_end
    conn.get_result

    # Events: StudentSubscribedToCourse
    conn.exec("COPY events (event_id, type, data, schema_version) FROM STDIN")
    pos = num_courses + 1
    join_rows = []
    num_students.times do |si|
      sid = "student-#{si}"
      courses = (0...num_courses).to_a.sample(subs_per_student)
      courses.each do |ci|
        cid = "course-#{ci}"
        conn.put_copy_data("#{SecureRandom.uuid}\tStudentSubscribedToCourse\t{\"student_id\":\"#{sid}\",\"course_id\":\"#{cid}\"}\t1\n")
        join_rows << [pos, tag_to_id["student:#{sid}"], tag_to_id["course:#{cid}"]]
        pos += 1
      end
    end
    conn.put_copy_end
    conn.get_result

    # Event tags for subscriptions
    conn.exec("COPY event_tags (sequence_position, tag_id) FROM STDIN")
    join_rows.each do |seq_pos, student_tag_id, course_tag_id|
      conn.put_copy_data("#{seq_pos}\t#{student_tag_id}\n")
      conn.put_copy_data("#{seq_pos}\t#{course_tag_id}\n")
    end
    conn.put_copy_end
    conn.get_result

    conn.exec("ANALYZE events")
    conn.exec("ANALYZE tags")
    conn.exec("ANALYZE event_tags")
  end

  # ============================================================================
  # Query helpers - resolve tag values to IDs (would be cached in production)
  # ============================================================================

  def self.resolve_tag_id(conn, tag_value)
    result = conn.exec_params("SELECT id FROM tags WHERE value = $1", [tag_value])
    result.ntuples > 0 ? result[0]["id"].to_i : nil
  end

  def self.resolve_tag_ids(conn, tag_values)
    tag_values.map { |v| resolve_tag_id(conn, v) }
  end

  # ============================================================================
  # Benchmark queries: Schema A (array)
  # ============================================================================

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

  # ============================================================================
  # Benchmark queries: Schema B (denormalized tags table)
  # ============================================================================

  def self.read_denorm_single_course(conn, course_id)
    conn.exec_params(
      <<~SQL, ["course:#{course_id}", "{CourseDefined,CourseCapacityChanged,StudentSubscribedToCourse}"]
        SELECT e.* FROM events e
        INNER JOIN event_tags et ON et.sequence_position = e.sequence_position
        WHERE et.tag = $1 AND e.type = ANY($2::text[])
        ORDER BY e.sequence_position
      SQL
    ).to_a
  end

  def self.read_denorm_single_student(conn, student_id)
    conn.exec_params(
      <<~SQL, ["student:#{student_id}", "{StudentSubscribedToCourse}"]
        SELECT e.* FROM events e
        INNER JOIN event_tags et ON et.sequence_position = e.sequence_position
        WHERE et.tag = $1 AND e.type = ANY($2::text[])
        ORDER BY e.sequence_position
      SQL
    ).to_a
  end

  def self.read_denorm_intersection(conn, student_id, course_id)
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

  def self.read_denorm_decision_model(conn, student_id, course_id)
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

  def self.count_denorm_condition(conn, student_id, course_id, after_pos)
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
  # Benchmark queries: Schema C (normalized tags - lookup + join)
  # ============================================================================

  def self.read_norm_single_course(conn, course_id)
    conn.exec_params(
      <<~SQL, ["course:#{course_id}", "{CourseDefined,CourseCapacityChanged,StudentSubscribedToCourse}"]
        SELECT e.* FROM events e
        INNER JOIN event_tags et ON et.sequence_position = e.sequence_position
        INNER JOIN tags t ON t.id = et.tag_id
        WHERE t.value = $1 AND e.type = ANY($2::text[])
        ORDER BY e.sequence_position
      SQL
    ).to_a
  end

  def self.read_norm_single_student(conn, student_id)
    conn.exec_params(
      <<~SQL, ["student:#{student_id}", "{StudentSubscribedToCourse}"]
        SELECT e.* FROM events e
        INNER JOIN event_tags et ON et.sequence_position = e.sequence_position
        INNER JOIN tags t ON t.id = et.tag_id
        WHERE t.value = $1 AND e.type = ANY($2::text[])
        ORDER BY e.sequence_position
      SQL
    ).to_a
  end

  def self.read_norm_intersection(conn, student_id, course_id)
    conn.exec_params(
      <<~SQL, ["student:#{student_id}", "course:#{course_id}", "{StudentSubscribedToCourse}"]
        SELECT e.* FROM events e
        INNER JOIN event_tags et ON et.sequence_position = e.sequence_position
        INNER JOIN tags t ON t.id = et.tag_id
        WHERE t.value IN ($1, $2) AND e.type = ANY($3::text[])
        GROUP BY e.sequence_position
        HAVING COUNT(DISTINCT t.value) = 2
        ORDER BY e.sequence_position
      SQL
    ).to_a
  end

  def self.read_norm_decision_model(conn, student_id, course_id)
    # UNION strategy: each branch resolves tag via join to tags table
    conn.exec_params(
      <<~SQL, [
        SELECT DISTINCT e.* FROM (
          SELECT e.sequence_position, e.event_id, e.type, e.data, e.causation_id,
                 e.correlation_id, e.schema_version, e.created_at
          FROM events e
          INNER JOIN event_tags et ON et.sequence_position = e.sequence_position
          INNER JOIN tags t ON t.id = et.tag_id
          WHERE t.value = $1
            AND e.type = ANY($3::text[])

          UNION

          SELECT e.sequence_position, e.event_id, e.type, e.data, e.causation_id,
                 e.correlation_id, e.schema_version, e.created_at
          FROM events e
          INNER JOIN event_tags et ON et.sequence_position = e.sequence_position
          INNER JOIN tags t ON t.id = et.tag_id
          WHERE t.value = $2
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

  def self.read_norm_decision_model_precached(conn, course_id, student_id, course_tag_id, student_tag_id)
    # Same UNION but using pre-resolved tag IDs — skips the tags table join entirely
    conn.exec_params(
      <<~SQL, [
        SELECT DISTINCT e.* FROM (
          SELECT e.sequence_position, e.event_id, e.type, e.data, e.causation_id,
                 e.correlation_id, e.schema_version, e.created_at
          FROM events e
          INNER JOIN event_tags et ON et.sequence_position = e.sequence_position
          WHERE et.tag_id = $1
            AND e.type = ANY($3::text[])

          UNION

          SELECT e.sequence_position, e.event_id, e.type, e.data, e.causation_id,
                 e.correlation_id, e.schema_version, e.created_at
          FROM events e
          INNER JOIN event_tags et ON et.sequence_position = e.sequence_position
          WHERE et.tag_id = $2
            AND e.type = ANY($4::text[])
        ) e
        ORDER BY e.sequence_position
      SQL
        course_tag_id,
        student_tag_id,
        "{CourseDefined,CourseCapacityChanged,StudentSubscribedToCourse}",
        "{StudentSubscribedToCourse}"
      ]
    ).to_a
  end

  def self.count_norm_condition(conn, student_id, course_id, after_pos)
    conn.exec_params(
      <<~SQL, [
        SELECT COUNT(*) FROM events e WHERE
          e.sequence_position > $3
          AND EXISTS (
            SELECT 1 FROM event_tags et
            INNER JOIN tags t ON t.id = et.tag_id
            WHERE et.sequence_position = e.sequence_position
            AND t.value IN ($1, $2)
          )
          AND (
            (e.type = ANY($4::text[])
             AND EXISTS (SELECT 1 FROM event_tags et INNER JOIN tags t ON t.id = et.tag_id
                         WHERE et.sequence_position = e.sequence_position AND t.value = $1))
            OR (e.type = ANY($5::text[])
                AND EXISTS (SELECT 1 FROM event_tags et INNER JOIN tags t ON t.id = et.tag_id
                            WHERE et.sequence_position = e.sequence_position AND t.value = $2))
            OR (e.type = ANY($6::text[])
                AND EXISTS (SELECT 1 FROM event_tags et INNER JOIN tags t ON t.id = et.tag_id
                            WHERE et.sequence_position = e.sequence_position AND t.value = $1)
                AND EXISTS (SELECT 1 FROM event_tags et INNER JOIN tags t ON t.id = et.tag_id
                            WHERE et.sequence_position = e.sequence_position AND t.value = $2))
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

  def self.count_norm_condition_precached(conn, course_tag_id, student_tag_id, after_pos)
    conn.exec_params(
      <<~SQL, [
        SELECT COUNT(*) FROM events e WHERE
          e.sequence_position > $3
          AND EXISTS (
            SELECT 1 FROM event_tags et
            WHERE et.sequence_position = e.sequence_position
            AND et.tag_id IN ($1, $2)
          )
          AND (
            (e.type = ANY($4::text[])
             AND EXISTS (SELECT 1 FROM event_tags et
                         WHERE et.sequence_position = e.sequence_position AND et.tag_id = $1))
            OR (e.type = ANY($5::text[])
                AND EXISTS (SELECT 1 FROM event_tags et
                            WHERE et.sequence_position = e.sequence_position AND et.tag_id = $2))
            OR (e.type = ANY($6::text[])
                AND EXISTS (SELECT 1 FROM event_tags et
                            WHERE et.sequence_position = e.sequence_position AND et.tag_id = $1)
                AND EXISTS (SELECT 1 FROM event_tags et
                            WHERE et.sequence_position = e.sequence_position AND et.tag_id = $2))
          )
      SQL
        course_tag_id,
        student_tag_id,
        after_pos,
        "{CourseDefined,CourseCapacityChanged,StudentSubscribedToCourse}",
        "{StudentSubscribedToCourse}",
        "{StudentSubscribedToCourse}"
      ]
    ).to_a
  end

  # ============================================================================
  # Table stats helper
  # ============================================================================

  def self.print_table_stats(conn, tables)
    tables.each do |table|
      result = conn.exec("SELECT count(*) as cnt, pg_size_pretty(pg_total_relation_size('#{table}')) as size FROM #{table}")
      row = result[0]
      puts "  #{table}: #{row["cnt"]} rows, size (incl. indexes): #{row["size"]}"
    end

    result = conn.exec(<<~SQL)
      SELECT indexname, tablename, pg_size_pretty(pg_relation_size(indexname::regclass)) as size
      FROM pg_indexes WHERE tablename IN (#{tables.map { |t| "'#{t}'" }.join(',')}) ORDER BY tablename, indexname
    SQL
    result.each { |r| puts "  Index #{r["indexname"]} (#{r["tablename"]}): #{r["size"]}" }

    if tables.size > 1
      size_sql = tables.map { |t| "pg_total_relation_size('#{t}')" }.join(" + ")
      combined = conn.exec("SELECT pg_size_pretty(#{size_sql}) as size")[0]["size"]
      puts "  Combined total: #{combined}"
    end
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

    puts "=" * 90
    puts "Experiment 10: Normalized Tags Table"
    puts "  #{num_students} students, #{num_courses} courses, #{n} iterations each"
    puts "=" * 90

    # ===========================================================================
    # SCHEMA A: TEXT[] with GIN (baseline)
    # ===========================================================================
    puts
    puts "#" * 90
    puts "# SCHEMA A: TEXT[] array with GIN index (baseline)"
    puts "#" * 90

    print "\nSetting up... "
    _, t = measure { setup_array_schema!(conn) }
    puts "(#{t.round(2)}s)"

    print "Seeding #{num_students * MAX_STUDENT_COURSES + num_courses} events... "
    _, t = measure do
      srand(42)
      seed_array!(conn, num_students, num_courses)
    end
    puts "(#{t.round(2)}s)"

    max_pos = conn.exec("SELECT MAX(sequence_position) as mp FROM events")[0]["mp"].to_i

    puts
    puts "--- Read queries ---"

    bench("Array: single course", iterations: n) do
      read_array_single_course(conn, "course-0")
    end

    bench("Array: single student", iterations: n) do
      read_array_single_student(conn, "student-0")
    end

    bench("Array: student+course intersection", iterations: n) do
      read_array_intersection(conn, "student-0", "course-0")
    end

    bench("Array: decision model (5 projections)", iterations: n) do
      read_array_decision_model(conn, "student-0", "course-0")
    end

    bench("Array: decision model random", iterations: n) do
      read_array_decision_model(conn, "student-#{rand(num_students)}", "course-#{rand(num_courses)}")
    end

    puts
    puts "--- Condition check ---"

    bench("Array: condition check (no conflict)", iterations: n) do
      count_array_condition(conn, "student-0", "course-0", max_pos)
    end

    puts
    puts "--- Table stats ---"
    print_table_stats(conn, ["events"])

    # ===========================================================================
    # SCHEMA B: Denormalized tags table (Exp 9 for comparison)
    # ===========================================================================
    puts
    puts "#" * 90
    puts "# SCHEMA B: Denormalized event_tags(pos, tag) — Exp 9 style"
    puts "#" * 90

    print "\nSetting up... "
    _, t = measure { setup_denorm_tags_schema!(conn) }
    puts "(#{t.round(2)}s)"

    print "Seeding... "
    _, t = measure do
      srand(42)
      seed_denorm_tags!(conn, num_students, num_courses)
    end
    puts "(#{t.round(2)}s)"

    max_pos = conn.exec("SELECT MAX(sequence_position) as mp FROM events")[0]["mp"].to_i

    puts
    puts "--- Read queries ---"

    bench("Denorm tags: single course", iterations: n) do
      read_denorm_single_course(conn, "course-0")
    end

    bench("Denorm tags: single student", iterations: n) do
      read_denorm_single_student(conn, "student-0")
    end

    bench("Denorm tags: student+course intersection", iterations: n) do
      read_denorm_intersection(conn, "student-0", "course-0")
    end

    bench("Denorm tags: decision model (UNION)", iterations: n) do
      read_denorm_decision_model(conn, "student-0", "course-0")
    end

    bench("Denorm tags: decision model random", iterations: n) do
      read_denorm_decision_model(conn, "student-#{rand(num_students)}", "course-#{rand(num_courses)}")
    end

    puts
    puts "--- Condition check ---"

    bench("Denorm tags: condition check (no conflict)", iterations: n) do
      count_denorm_condition(conn, "student-0", "course-0", max_pos)
    end

    puts
    puts "--- Table stats ---"
    print_table_stats(conn, ["events", "event_tags"])

    # ===========================================================================
    # SCHEMA C: Fully normalized tags (lookup + join)
    # ===========================================================================
    puts
    puts "#" * 90
    puts "# SCHEMA C: Normalized tags(id, value) + event_tags(pos, tag_id)"
    puts "#" * 90

    print "\nSetting up... "
    _, t = measure { setup_normalized_tags_schema!(conn) }
    puts "(#{t.round(2)}s)"

    print "Seeding... "
    _, t = measure do
      srand(42)
      seed_normalized_tags!(conn, num_students, num_courses)
    end
    puts "(#{t.round(2)}s)"

    max_pos = conn.exec("SELECT MAX(sequence_position) as mp FROM events")[0]["mp"].to_i

    # Pre-resolve tag IDs for the "cached" variants
    course_tag_id = resolve_tag_id(conn, "course:course-0")
    student_tag_id = resolve_tag_id(conn, "student:student-0")

    puts
    puts "--- Read queries (resolving tag values at query time) ---"

    bench("Normalized: single course", iterations: n) do
      read_norm_single_course(conn, "course-0")
    end

    bench("Normalized: single student", iterations: n) do
      read_norm_single_student(conn, "student-0")
    end

    bench("Normalized: student+course intersection", iterations: n) do
      read_norm_intersection(conn, "student-0", "course-0")
    end

    bench("Normalized: decision model (UNION)", iterations: n) do
      read_norm_decision_model(conn, "student-0", "course-0")
    end

    bench("Normalized: decision model random", iterations: n) do
      read_norm_decision_model(conn, "student-#{rand(num_students)}", "course-#{rand(num_courses)}")
    end

    puts
    puts "--- Read queries (pre-cached tag IDs — skips tags table join) ---"

    bench("Norm+cached: decision model (UNION)", iterations: n) do
      read_norm_decision_model_precached(conn, "course-0", "student-0", course_tag_id, student_tag_id)
    end

    bench("Norm+cached: decision model random", iterations: n) do
      si = rand(num_students)
      ci = rand(num_courses)
      ct = resolve_tag_id(conn, "course:course-#{ci}")
      st = resolve_tag_id(conn, "student:student-#{si}")
      read_norm_decision_model_precached(conn, "course-#{ci}", "student-#{si}", ct, st)
    end

    puts
    puts "--- Condition check ---"

    bench("Normalized: condition check (no conflict)", iterations: n) do
      count_norm_condition(conn, "student-0", "course-0", max_pos)
    end

    bench("Norm+cached: condition check (no conflict)", iterations: n) do
      count_norm_condition_precached(conn, course_tag_id, student_tag_id, max_pos)
    end

    puts
    puts "--- Table stats ---"
    print_table_stats(conn, ["events", "tags", "event_tags"])

    # ===========================================================================
    # Correctness check
    # ===========================================================================
    puts
    puts "--- Correctness check ---"

    # Re-seed all schemas with same seed
    srand(42)
    setup_array_schema!(conn)
    seed_array!(conn, num_students, num_courses)
    a_course = read_array_single_course(conn, "course-0").size
    a_student = read_array_single_student(conn, "student-0").size
    a_inter = read_array_intersection(conn, "student-0", "course-0").size
    a_dm = read_array_decision_model(conn, "student-0", "course-0").size

    srand(42)
    setup_denorm_tags_schema!(conn)
    seed_denorm_tags!(conn, num_students, num_courses)
    b_course = read_denorm_single_course(conn, "course-0").size
    b_student = read_denorm_single_student(conn, "student-0").size
    b_inter = read_denorm_intersection(conn, "student-0", "course-0").size
    b_dm = read_denorm_decision_model(conn, "student-0", "course-0").size

    srand(42)
    setup_normalized_tags_schema!(conn)
    seed_normalized_tags!(conn, num_students, num_courses)
    c_course = read_norm_single_course(conn, "course-0").size
    c_student = read_norm_single_student(conn, "student-0").size
    c_inter = read_norm_intersection(conn, "student-0", "course-0").size
    c_dm = read_norm_decision_model(conn, "student-0", "course-0").size

    ct = resolve_tag_id(conn, "course:course-0")
    st = resolve_tag_id(conn, "student:student-0")
    c_dm_cached = read_norm_decision_model_precached(conn, "course-0", "student-0", ct, st).size

    all_ok = true
    [
      ["Course-0 events", a_course, b_course, c_course],
      ["Student-0 events", a_student, b_student, c_student],
      ["Intersection", a_inter, b_inter, c_inter],
      ["Decision model", a_dm, b_dm, c_dm],
    ].each do |label, a, b, c|
      ok = a == b && b == c
      all_ok &&= ok
      puts "  %-25s  array=%d  denorm=%d  normalized=%d  %s" % [label, a, b, c, ok ? "OK" : "MISMATCH!"]
    end

    dm_cache_ok = a_dm == c_dm_cached
    all_ok &&= dm_cache_ok
    puts "  %-25s  array=%d  cached=%d  %s" % ["DM (cached IDs)", a_dm, c_dm_cached, dm_cache_ok ? "OK" : "MISMATCH!"]

    puts
    puts all_ok ? "All correctness checks passed." : "*** CORRECTNESS FAILURES DETECTED ***"
    puts
    puts "Done."
  ensure
    conn&.close
  end
end

NormalizedTagsBenchmark.run if __FILE__ == $0
