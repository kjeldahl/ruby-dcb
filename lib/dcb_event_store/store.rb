require "json"
require "time"

module DcbEventStore
  class Store
    include StoreInstrumentation

    BATCH_SIZE = 1000

    def initialize(conn, upcaster: nil, subscribe_instrumentation: :event)
      @conn = conn
      @codec = PgArrayCodec.new
      @sql = SqlBuilder.new(@codec)
      @row_mapper = RowMapper.new(@codec, upcaster)
      @subscribe_instrumentation = subscribe_instrumentation_mode(subscribe_instrumentation)
    end

    def read(query)
      instrument_read(paginated_read(query, after: nil), query, nil)
    end

    def read_from(query, after:)
      instrument_read(paginated_read(query, after: after), query, after)
    end

    def append(events, condition = nil)
      events = Array(events)
      instrument_append(events, condition) do
        with_transaction do
          acquire_locks!(condition)

          sequenced = if condition
                        append_with_condition(events, condition)
                      else
                        append_without_condition(events)
                      end

          notify_position = sequenced.last&.sequence_position
          @conn.exec("NOTIFY events_appended, '#{notify_position}'") if notify_position

          sequenced
        end
      end
    end

    def subscribe(query, after: nil, &block)
      catch_up = after ? read_from(query, after: after) : read(query)
      last_pos = instrument_subscribe(catch_up, query, :catch_up, &block) || after

      @conn.exec("LISTEN events_appended")
      loop do
        @conn.wait_for_notify do |_channel, _pid, _payload|
          new_events = read_from(query, after: last_pos || 0)
          last_pos = instrument_subscribe(new_events, query, :live, &block) || last_pos
        end
      end
    ensure
      begin
        @conn.exec("UNLISTEN events_appended")
      rescue StandardError
        nil
      end
    end

    private

    def paginated_read(query, after:)
      Enumerator.new do |yielder|
        cursor = after
        loop do
          sql, params = @sql.read_sql(query, after: cursor)
          result = @conn.exec_params("#{sql} LIMIT #{BATCH_SIZE}", params)
          break if result.ntuples.zero?

          result.each do |row|
            cursor = row["sequence_position"].to_i
            yielder << @row_mapper.to_sequenced_event(row)
          end
          break if result.ntuples < BATCH_SIZE
        end
      end
    end

    def acquire_locks!(condition)
      keys = LockKeys.for(condition)
      pg_arr = "{#{keys.join(',')}}"
      @conn.exec_params("SELECT acquire_sorted_advisory_locks($1::bigint[])", [pg_arr])
    end

    def append_with_condition(events, condition)
      cond_sql, cond_params = @sql.count_sql(condition.fail_if_events_match, after: condition.after)
      value_rows, insert_params = @sql.values_clause(events, cond_params.size)

      result = @conn.exec_params(
        <<~SQL,
          WITH cond AS (#{cond_sql})
          INSERT INTO events (event_id, type, data, tags, causation_id, correlation_id, schema_version)
          SELECT v.* FROM (VALUES #{value_rows.join(', ')})
            AS v(event_id, type, data, tags, causation_id, correlation_id, schema_version)
          WHERE NOT EXISTS (SELECT 1 FROM cond WHERE count > 0)
          ON CONFLICT (event_id) DO NOTHING
          RETURNING event_id, sequence_position, created_at
        SQL
        cond_params + insert_params
      )

      if result.ntuples.zero? && events.any?
        check = @conn.exec_params(cond_sql, cond_params)
        raise ConditionNotMet, "conflicting event(s)" if check[0]["count"].to_i.positive?

        return []
      end

      events_by_id = events.to_h { |e| [e.id, e] }
      result.map do |row|
        @row_mapper.to_appended_event(events_by_id[row["event_id"]], row)
      end
    end

    def append_without_condition(events)
      events.filter_map do |event|
        result = @conn.exec_params(
          <<~SQL,
            INSERT INTO events (event_id, type, data, tags, causation_id, correlation_id, schema_version)
            VALUES ($1, $2, $3::jsonb, $4::text[], $5, $6, $7)
            ON CONFLICT (event_id) DO NOTHING
            RETURNING sequence_position, created_at
          SQL
          [event.id, event.type, JSON.generate(event.data), @codec.encode(event.tags),
           event.causation_id, event.correlation_id, 1]
        )
        next nil if result.ntuples.zero?

        @row_mapper.to_appended_event(event, result[0])
      end
    end

    def with_transaction
      @conn.exec("BEGIN")
      result = yield
      @conn.exec("COMMIT")
      result
    rescue StandardError
      begin
        @conn.exec("ROLLBACK")
      rescue StandardError
        nil
      end
      raise
    end
  end
end
