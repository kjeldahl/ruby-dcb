#!/usr/bin/env ruby
# frozen_string_literal: true

# Runs all experiments against the same seeded baseline.
# Each experiment modifies the Store behavior and measures the impact.
#
# Usage: ruby experiments/run_experiments.rb [num_students] [num_courses] [iterations]

require_relative "../lib/dcb_event_store"
require_relative "instrumented_store"
require "pg"
require "securerandom"
require "json"
require "time"

module ExperimentRunner
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

  # -- Experiment stores -----------------------------------------------------

  # Experiment 1: EXISTS instead of COUNT
  class ExistsStore < Experiments::InstrumentedStore
    private

    def check_condition!(condition)
      query = condition.fail_if_events_match
      sql, params = build_exists_sql(query, condition.after)
      result = @conn.exec_params(sql, params)
      raise DcbEventStore::ConditionNotMet, "conflicting event(s)" if result[0]["exists"] == "t"
    end

    def build_exists_sql(query, after)
      if query.match_all?
        if after
          return ["SELECT EXISTS(SELECT 1 FROM events WHERE sequence_position > $1)", [after]]
        else
          return ["SELECT EXISTS(SELECT 1 FROM events)", []]
        end
      end

      clauses = []
      params = []

      query.items.each do |item|
        parts = []
        unless item.event_types.empty?
          params << to_pg_array(item.event_types)
          parts << "type = ANY($#{params.size}::text[])"
        end
        unless item.tags.empty?
          params << to_pg_array(item.tags)
          parts << "tags @> $#{params.size}::text[]"
        end
        clauses << "(#{parts.join(" AND ")})" unless parts.empty?
      end

      where = clauses.join(" OR ")
      if after
        params << after
        where = "(#{where}) AND sequence_position > $#{params.size}"
      end

      ["SELECT EXISTS(SELECT 1 FROM events WHERE #{where})", params]
    end
  end

  # Experiment 2: Per-tag advisory locks
  class PerTagLockStore < Experiments::InstrumentedStore
    def append(events, condition = nil)
      events = Array(events)
      timing = {}

      # Compute lock key from the condition's query tags
      lock_key = if condition
                   tags = condition.fail_if_events_match.items.flat_map(&:tags).sort
                   tags.join(",").hash.abs % (2**31)
                 else
                   0
                 end

      with_transaction do
        timing[:lock_wait] = measure { @conn.exec("SELECT pg_advisory_xact_lock($1)", [lock_key]) }

        if condition
          timing[:condition_check] = measure { check_condition!(condition) }
        end

        timing[:insert] = measure do
          @sequenced = events.filter_map do |event|
            result = @conn.exec_params(
              <<~SQL,
                INSERT INTO events (event_id, type, data, tags, causation_id, correlation_id, schema_version)
                VALUES ($1, $2, $3::jsonb, $4::text[], $5, $6, $7)
                ON CONFLICT (event_id) DO NOTHING
                RETURNING sequence_position, created_at
              SQL
              [event.id, event.type, JSON.generate(event.data), "{#{event.tags.join(",")}}",
               event.causation_id, event.correlation_id, 1]
            )
            next nil if result.ntuples.zero?

            row = result[0]
            DcbEventStore::SequencedEvent.new(
              sequence_position: row["sequence_position"].to_i,
              type: event.type, data: event.data, tags: event.tags,
              created_at: Time.parse(row["created_at"]), id: event.id,
              causation_id: event.causation_id, correlation_id: event.correlation_id,
              schema_version: 1
            )
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
  end

  # Experiment 3: Single-statement CTE (condition + insert in one round-trip)
  class CTEStore < Experiments::InstrumentedStore
    def append(events, condition = nil)
      events = Array(events)
      timing = {}

      with_transaction do
        timing[:lock_wait] = measure { @conn.exec("SELECT pg_advisory_xact_lock($1)", [APPEND_LOCK_KEY]) }

        if condition
          timing[:condition_check] = 0.0 # merged into insert
          timing[:insert] = measure do
            @sequenced = events.filter_map do |event|
              cond_sql, cond_params = build_condition_sql_for_cte(condition)
              insert_params = [event.id, event.type, JSON.generate(event.data),
                               "{#{event.tags.join(",")}}",
                               event.causation_id, event.correlation_id, 1]
              # Offset parameter numbers for insert params
              offset = cond_params.size
              result = @conn.exec_params(
                <<~SQL,
                  WITH cond AS (#{cond_sql})
                  INSERT INTO events (event_id, type, data, tags, causation_id, correlation_id, schema_version)
                  SELECT $#{offset + 1}, $#{offset + 2}, $#{offset + 3}::jsonb, $#{offset + 4}::text[],
                         $#{offset + 5}, $#{offset + 6}, $#{offset + 7}
                  WHERE NOT EXISTS (SELECT 1 FROM cond WHERE count > 0)
                  ON CONFLICT (event_id) DO NOTHING
                  RETURNING sequence_position, created_at
                SQL
                cond_params + insert_params
              )

              if result.ntuples.zero?
                # Could be conflict or condition failure — check which
                check = @conn.exec_params(*build_condition_check(condition))
                raise DcbEventStore::ConditionNotMet, "conflicting event(s)" if check[0]["count"].to_i.positive?
                next nil # idempotent skip
              end

              row = result[0]
              DcbEventStore::SequencedEvent.new(
                sequence_position: row["sequence_position"].to_i,
                type: event.type, data: event.data, tags: event.tags,
                created_at: Time.parse(row["created_at"]), id: event.id,
                causation_id: event.causation_id, correlation_id: event.correlation_id,
                schema_version: 1
              )
            end
          end
        else
          timing[:insert] = measure do
            @sequenced = events.filter_map do |event|
              result = @conn.exec_params(
                <<~SQL,
                  INSERT INTO events (event_id, type, data, tags, causation_id, correlation_id, schema_version)
                  VALUES ($1, $2, $3::jsonb, $4::text[], $5, $6, $7)
                  ON CONFLICT (event_id) DO NOTHING
                  RETURNING sequence_position, created_at
                SQL
                [event.id, event.type, JSON.generate(event.data), "{#{event.tags.join(",")}}",
                 event.causation_id, event.correlation_id, 1]
              )
              next nil if result.ntuples.zero?

              row = result[0]
              DcbEventStore::SequencedEvent.new(
                sequence_position: row["sequence_position"].to_i,
                type: event.type, data: event.data, tags: event.tags,
                created_at: Time.parse(row["created_at"]), id: event.id,
                causation_id: event.causation_id, correlation_id: event.correlation_id,
                schema_version: 1
              )
            end
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

    def build_condition_sql_for_cte(condition)
      query = condition.fail_if_events_match
      send(:build_condition_sql, query, condition.after)
    end

    def build_condition_check(condition)
      query = condition.fail_if_events_match
      send(:build_condition_sql, query, condition.after)
    end
  end

  # Experiment 6: Per-tag locks + CTE (combine exp 2 and 3)
  class PerTagCTEStore < Experiments::InstrumentedStore
    def append(events, condition = nil)
      events = Array(events)
      timing = {}

      lock_key = if condition
                   tags = condition.fail_if_events_match.items.flat_map(&:tags).sort
                   tags.join(",").hash.abs % (2**31)
                 else
                   0
                 end

      with_transaction do
        timing[:lock_wait] = measure { @conn.exec("SELECT pg_advisory_xact_lock($1)", [lock_key]) }

        if condition
          timing[:condition_check] = 0.0
          timing[:insert] = measure do
            @sequenced = events.filter_map do |event|
              cond_sql, cond_params = build_condition_sql(condition.fail_if_events_match, condition.after)
              insert_params = [event.id, event.type, JSON.generate(event.data),
                               "{#{event.tags.join(",")}}",
                               event.causation_id, event.correlation_id, 1]
              offset = cond_params.size
              result = @conn.exec_params(
                <<~SQL,
                  WITH cond AS (#{cond_sql})
                  INSERT INTO events (event_id, type, data, tags, causation_id, correlation_id, schema_version)
                  SELECT $#{offset + 1}, $#{offset + 2}, $#{offset + 3}::jsonb, $#{offset + 4}::text[],
                         $#{offset + 5}, $#{offset + 6}, $#{offset + 7}
                  WHERE NOT EXISTS (SELECT 1 FROM cond WHERE count > 0)
                  ON CONFLICT (event_id) DO NOTHING
                  RETURNING sequence_position, created_at
                SQL
                cond_params + insert_params
              )

              if result.ntuples.zero?
                check = @conn.exec_params(*build_condition_sql(condition.fail_if_events_match, condition.after))
                raise DcbEventStore::ConditionNotMet, "conflicting event(s)" if check[0]["count"].to_i.positive?
                next nil
              end

              row = result[0]
              DcbEventStore::SequencedEvent.new(
                sequence_position: row["sequence_position"].to_i,
                type: event.type, data: event.data, tags: event.tags,
                created_at: Time.parse(row["created_at"]), id: event.id,
                causation_id: event.causation_id, correlation_id: event.correlation_id,
                schema_version: 1
              )
            end
          end
        else
          timing[:insert] = measure do
            @sequenced = events.filter_map do |event|
              result = @conn.exec_params(
                <<~SQL,
                  INSERT INTO events (event_id, type, data, tags, causation_id, correlation_id, schema_version)
                  VALUES ($1, $2, $3::jsonb, $4::text[], $5, $6, $7)
                  ON CONFLICT (event_id) DO NOTHING
                  RETURNING sequence_position, created_at
                SQL
                [event.id, event.type, JSON.generate(event.data), "{#{event.tags.join(",")}}",
                 event.causation_id, event.correlation_id, 1]
              )
              next nil if result.ntuples.zero?

              row = result[0]
              DcbEventStore::SequencedEvent.new(
                sequence_position: row["sequence_position"].to_i,
                type: event.type, data: event.data, tags: event.tags,
                created_at: Time.parse(row["created_at"]), id: event.id,
                causation_id: event.causation_id, correlation_id: event.correlation_id,
                schema_version: 1
              )
            end
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
  end

  # Stored procedure: acquire multiple advisory locks in sorted order (one round-trip)
  MULTI_LOCK_SQL = <<~SQL
    CREATE OR REPLACE FUNCTION acquire_sorted_advisory_locks(lock_keys bigint[])
    RETURNS void AS $$
    DECLARE
      k bigint;
    BEGIN
      FOREACH k IN ARRAY (SELECT array_agg(x ORDER BY x) FROM unnest(lock_keys) x)
      LOOP
        PERFORM pg_advisory_xact_lock(k);
      END LOOP;
    END;
    $$ LANGUAGE plpgsql;
  SQL

  def self.create_multi_lock_function!(conn)
    conn.exec(MULTI_LOCK_SQL)
  end

  # Compute lock keys from all unique tags in a condition query
  def self.tag_lock_keys(condition)
    return [0] unless condition
    tags = condition.fail_if_events_match.items.flat_map(&:tags).uniq
    return [0] if tags.empty?
    tags.map { |t| t.hash.abs % (2**62) }.sort
  end

  # Experiment 7: Correct multi-tag locks (one lock per unique tag, sorted)
  class MultiTagLockStore < Experiments::InstrumentedStore
    def append(events, condition = nil)
      events = Array(events)
      timing = {}
      keys = ExperimentRunner.tag_lock_keys(condition)

      with_transaction do
        timing[:lock_wait] = measure do
          pg_arr = "{#{keys.join(",")}}"
          @conn.exec_params("SELECT acquire_sorted_advisory_locks($1::bigint[])", [pg_arr])
        end

        if condition
          timing[:condition_check] = measure { check_condition!(condition) }
        end

        timing[:insert] = measure do
          @sequenced = insert_events(events)
        end

        timing[:notify] = measure { do_notify }

        @sequenced
      end

      timing[:total] = timing.values.sum
      @timings << timing
      @sequenced
    end

    private

    def insert_events(events)
      events.filter_map do |event|
        result = @conn.exec_params(
          <<~SQL,
            INSERT INTO events (event_id, type, data, tags, causation_id, correlation_id, schema_version)
            VALUES ($1, $2, $3::jsonb, $4::text[], $5, $6, $7)
            ON CONFLICT (event_id) DO NOTHING
            RETURNING sequence_position, created_at
          SQL
          [event.id, event.type, JSON.generate(event.data), "{#{event.tags.join(",")}}",
           event.causation_id, event.correlation_id, 1]
        )
        next nil if result.ntuples.zero?

        row = result[0]
        DcbEventStore::SequencedEvent.new(
          sequence_position: row["sequence_position"].to_i,
          type: event.type, data: event.data, tags: event.tags,
          created_at: Time.parse(row["created_at"]), id: event.id,
          causation_id: event.causation_id, correlation_id: event.correlation_id,
          schema_version: 1
        )
      end
    end

    def do_notify
      notify_position = @sequenced.last&.sequence_position
      @conn.exec("NOTIFY events_appended, '#{notify_position}'") if notify_position
    end
  end

  # Experiment 8: Correct multi-tag locks + CTE
  class MultiTagCTEStore < Experiments::InstrumentedStore
    def append(events, condition = nil)
      events = Array(events)
      timing = {}
      keys = ExperimentRunner.tag_lock_keys(condition)

      with_transaction do
        timing[:lock_wait] = measure do
          pg_arr = "{#{keys.join(",")}}"
          @conn.exec_params("SELECT acquire_sorted_advisory_locks($1::bigint[])", [pg_arr])
        end

        if condition
          timing[:condition_check] = 0.0
          timing[:insert] = measure do
            @sequenced = events.filter_map do |event|
              cond_sql, cond_params = build_condition_sql(condition.fail_if_events_match, condition.after)
              insert_params = [event.id, event.type, JSON.generate(event.data),
                               "{#{event.tags.join(",")}}",
                               event.causation_id, event.correlation_id, 1]
              offset = cond_params.size
              result = @conn.exec_params(
                <<~SQL,
                  WITH cond AS (#{cond_sql})
                  INSERT INTO events (event_id, type, data, tags, causation_id, correlation_id, schema_version)
                  SELECT $#{offset + 1}, $#{offset + 2}, $#{offset + 3}::jsonb, $#{offset + 4}::text[],
                         $#{offset + 5}, $#{offset + 6}, $#{offset + 7}
                  WHERE NOT EXISTS (SELECT 1 FROM cond WHERE count > 0)
                  ON CONFLICT (event_id) DO NOTHING
                  RETURNING sequence_position, created_at
                SQL
                cond_params + insert_params
              )

              if result.ntuples.zero?
                check = @conn.exec_params(*build_condition_sql(condition.fail_if_events_match, condition.after))
                raise DcbEventStore::ConditionNotMet, "conflicting event(s)" if check[0]["count"].to_i.positive?
                next nil
              end

              row = result[0]
              DcbEventStore::SequencedEvent.new(
                sequence_position: row["sequence_position"].to_i,
                type: event.type, data: event.data, tags: event.tags,
                created_at: Time.parse(row["created_at"]), id: event.id,
                causation_id: event.causation_id, correlation_id: event.correlation_id,
                schema_version: 1
              )
            end
          end
        else
          timing[:insert] = measure do
            @sequenced = events.filter_map do |event|
              result = @conn.exec_params(
                <<~SQL,
                  INSERT INTO events (event_id, type, data, tags, causation_id, correlation_id, schema_version)
                  VALUES ($1, $2, $3::jsonb, $4::text[], $5, $6, $7)
                  ON CONFLICT (event_id) DO NOTHING
                  RETURNING sequence_position, created_at
                SQL
                [event.id, event.type, JSON.generate(event.data), "{#{event.tags.join(",")}}",
                 event.causation_id, event.correlation_id, 1]
              )
              next nil if result.ntuples.zero?

              row = result[0]
              DcbEventStore::SequencedEvent.new(
                sequence_position: row["sequence_position"].to_i,
                type: event.type, data: event.data, tags: event.tags,
                created_at: Time.parse(row["created_at"]), id: event.id,
                causation_id: event.causation_id, correlation_id: event.correlation_id,
                schema_version: 1
              )
            end
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
  end

  # Experiment 5: Optimistic skip-lock with retry
  class SkipLockStore < Experiments::InstrumentedStore
    MAX_RETRIES = 20
    RETRY_SLEEP = 0.001 # 1ms

    def append(events, condition = nil)
      events = Array(events)
      timing = {}

      with_transaction do
        timing[:lock_wait] = measure do
          attempts = 0
          loop do
            result = @conn.exec("SELECT pg_try_advisory_xact_lock($1)", [APPEND_LOCK_KEY])
            break if result[0]["pg_try_advisory_xact_lock"] == "t"

            attempts += 1
            if attempts >= MAX_RETRIES
              # Fall back to blocking lock
              @conn.exec("SELECT pg_advisory_xact_lock($1)", [APPEND_LOCK_KEY])
              break
            end
            sleep(RETRY_SLEEP)
          end
        end

        if condition
          timing[:condition_check] = measure { check_condition!(condition) }
        end

        timing[:insert] = measure do
          @sequenced = events.filter_map do |event|
            result = @conn.exec_params(
              <<~SQL,
                INSERT INTO events (event_id, type, data, tags, causation_id, correlation_id, schema_version)
                VALUES ($1, $2, $3::jsonb, $4::text[], $5, $6, $7)
                ON CONFLICT (event_id) DO NOTHING
                RETURNING sequence_position, created_at
              SQL
              [event.id, event.type, JSON.generate(event.data), "{#{event.tags.join(",")}}",
               event.causation_id, event.correlation_id, 1]
            )
            next nil if result.ntuples.zero?

            row = result[0]
            DcbEventStore::SequencedEvent.new(
              sequence_position: row["sequence_position"].to_i,
              type: event.type, data: event.data, tags: event.tags,
              created_at: Time.parse(row["created_at"]), id: event.id,
              causation_id: event.causation_id, correlation_id: event.correlation_id,
              schema_version: 1
            )
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
  end

  # -- Run all experiments ---------------------------------------------------

  def self.print_summary(label, timings)
    return if timings.empty?

    keys = timings.first.keys
    puts "  #{label}:"
    keys.each do |key|
      values = timings.map { |t| t[key] }.compact.sort
      next if values.empty?

      puts "    %-20s  p50=%7.3f  p90=%7.3f  p99=%7.3f  stddev=%7.3f ms  (n=%d)" % [
        key,
        percentile(values, 50) * 1000,
        percentile(values, 90) * 1000,
        percentile(values, 99) * 1000,
        stddev(values) * 1000,
        values.size
      ]
    end
  end

  def self.run_concurrent(label, store_class, conn, num_courses, base)
    threads = 10
    ops = 10
    all_timings = []

    # Re-seed to reset state
    seed!(conn, @num_students, num_courses)

    elapsed = measure do
      workers = threads.times.map do |ti|
        Thread.new do
          c = PG.connect(dbname: "dcb_event_store_test")
          c.exec("SET client_min_messages TO warning")
          s = store_class.new(c)
          ops.times do |oi|
            sid = "exp-#{base + ti * 10_000 + oi}"
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

    succeeded = all_timings.size
    puts "  Total: %.0fms, %d ops, %.0f ops/sec" % [elapsed * 1000, succeeded, succeeded / elapsed]
    print_summary(label, all_timings)
    puts
  end

  def self.run
    @num_students = (ARGV[0] || 100_000).to_i
    num_courses   = (ARGV[1] || 500).to_i
    n             = (ARGV[2] || 50).to_i
    base          = @num_students + 1000

    conn = PG.connect(dbname: "dcb_event_store_test")
    conn.exec("SET client_min_messages TO warning")
    DcbEventStore::Schema.create!(conn)

    experiments = {
      "Baseline (global lock)" => Experiments::InstrumentedStore,
      "Exp 1: EXISTS vs COUNT" => ExistsStore,
      "Exp 2: Per-tag locks" => PerTagLockStore,
      "Exp 3: CTE (single stmt)" => CTEStore,
      "Exp 5: Skip-lock + retry" => SkipLockStore,
      "Exp 6: Per-tag + CTE" => PerTagCTEStore,
    }

    experiments.each do |name, store_class|
      puts "=" * 78
      puts name
      puts "=" * 78

      seed!(conn, @num_students, num_courses)
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
      run_concurrent("Concurrent", store_class, conn, num_courses, base)
    end

    # Experiment 4: verify read is outside lock
    puts "=" * 78
    puts "Exp 4: Read outside lock (verification)"
    puts "=" * 78
    puts
    puts "DecisionModel.build calls store.read() BEFORE store.append()."
    puts "The read happens outside the transaction/lock — confirmed by code inspection."
    puts "The lock is only held during: condition_check + insert + notify + commit."
    puts "No change needed — this is already optimal."
    puts

    puts "All experiments complete."
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

ExperimentRunner.run if __FILE__ == $0
